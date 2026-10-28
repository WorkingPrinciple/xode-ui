# Licensing boundaries

SPDX-License-Identifier: GPL-3.0-only

The user explicitly selected **GNU General Public License version 3** for this public app. [LICENSE](../LICENSE) contains the verbatim GNU GPL v3 text, dated 29 June 2007. Original app source, tests, documentation, fixture data, original artwork and mockup/export tooling in this repository are provided under **GPL-3.0-only**, not GPL-3.0-or-later.

The choice is user-directed and matches the reported GPL v3 license at the Xodus fork root. A license template's illustrative "or later" wording does not itself change this app's explicit grant. Source files identify GPL-3.0-only; this document states the grant for original repository material, including generated SVG/PNG artifacts.

The source repository does not bundle proprietary game packages, Microsoft/Apple artwork, paid design assets or fonts. Mockup/system typography uses fonts installed by the operating system. Built app candidates do include the separately built Xodus CLI and Windows monitor; their exact source, dependency licences, notices and corresponding-source obligations must be reviewed independently of this repository's licence. A local signed candidate is not a cleared distribution.

Future runtime components, libraries and assets retain their own licenses. The app license is not a grant to redistribute Wine variants, Microsoft game packages, platform SDK material, trademarks or third-party content. Before packaging, maintain a component/version/license/notice/source-offer manifest and review obligations for the exact paired runtime. GPL app distribution must include the required notices and corresponding source by an appropriate GPL-compliant route.

Signing, notarization, installer/updater channel and the detailed component redistribution review remain release blockers. This foundation makes no legal determination about future consumer APIs or package distribution.

## COR176 package boundary

The source-bound 2794e68 local candidate is historical and includes the app,
AuthHost, r7 CLI (producer `01d4cfd625764c2a8ec4d60824ef4f277b30b9e9`),
Windows monitor,
management schemas, launch policy, compatibility data, original icon and GPL
text. The AWACY-derived compatibility data retains its MIT notice at
`CompatibilityData/AWACY-LICENSE.txt`. Wine/Calimocho, CrossOver, GPTK,
graphics shims and games are user-installed dependencies, not bundled engines;
their presence on a development machine grants no redistribution rights.

Packaging now allowlists the resources consumed by the management readers.
Private queue and candidate-inspection JSON lives outside the runtime resource
directories, so it is excluded from every build configuration rather than only
the shipping build. Required launch policies are retained byte-for-byte;
removing or rewriting their identity-bound engine paths is not a safe
portability fix. The current `engine-defaults-v1.json` still references
development worktrees, so a portable final distribution remains blocked until
the engine owners provide a reviewed portable binding.

Before any external submission, inventory the exact final app/CLI/helper and
all bundled dependencies with versions, source revisions, licence texts,
copyright notices, corresponding-source delivery and an explicit rights-review
outcome. The app GPL text and source archive do not by themselves establish
complete CLI/helper dependency compliance. No such completed review is claimed
here.

### Exact producer notices and optional payloads

`tools/producer_notices.py` prepares an offline inventory from the selected
producer manifest, its hash-bound `post-build-native-metadata.json` and
`release-artifacts.jsonl`, and that producer commit's `Cargo.lock`. Registry
notice texts come from cached `.crate` archives verified against lockfile
checksums; Git dependency notices come from the locked revision, not a mutable
checkout. No credential access, download, build or external submission occurs.
The output records the metadata superset and distinguishes compiler-artifact
packages, including host/build/proc-macro dependencies. It is not a claim that
every recorded package is linked into the shipping executable.

For the prior -04 beta producer (`99e20addf88932de7796fc966fe09e00b71e4981`, tree
`7f9e8cc5bd10f696ea508f0ff9f2da3a7eaf2e91`), the initial generated inventory
was SHA-256 `ec3d8e79fe0472c84356cbc2285fa3ff2fb1ea65c481d58bc6e190cc27b15066`.
It covered 479 package identities, 462 compiler-artifact identities and 326
content-addressed notice texts, with 14 unresolved obligations. That baseline
was superseded by the reviewed successor below. The corresponding-source
archive is SHA-256
`d67b903137c96479298a139374d5bdf988db4f64ee971588183584bf520e4fdd` (9,574,400
bytes; 533 regular files); it is from that exact commit and omits
`docs/private-ai/` and `docs/private-checkpoints/`. The source tar contains
`DO_NOT_UPSTREAM` and is private-tester-only; the builder binds its exact hash
and refuses a substituted archive.

A successor notice inventory for the same producer commit is SHA-256
`5c27f9e24c78f7499fc5cf230b4a9e053c8e079f7880f4ddbfcc9f7a155d457e`. It
retains the 479 package and 462 compiler-artifact identities and has one
unresolved obligation covering final corresponding-source delivery and
applicable licence/notice review. The private-tester ZIP and DMG builders bind
the source archive, but its GitHub draft-release asset is still pending the
frozen integrated commit for tag `v0.2.0-beta.1`. The inventory and its supplemental evidence
(`77601f7da9cb9298973e568c0882230f1059e233b5118089ad3535bfed25d5a2`) were
independently approved by Ode and are pinned by the beta and release builders;
both package and release receipts record these pins. The inventory and
evidence establish provenance and notice-text identity, not legal clearance.
Do not publish the draft or source archive before the source asset is attached
and the owner makes the publication decision.

The installed -06 producer is `399957962f35eee6189b8fbcef9697f47e951581`
(tree `6d9088562be95b466c4a6df5b102c3f24a72048c`), with signed manifest
`79bcfad5747ffbffed13542f7fadb805a509225197912ce16273ea38c9a8a84d`, CLI
`f77208c9fce39993b12d2bb649ea4a0de3a592dfcbe0d2101dea712d6d13713f`, and
Windows helper `c205a45fcfa703296593034498a35c177ad7e9c80fdd1a4ddeec2fdb721bface`.
Its corresponding-source archive
`xodus-cli-beta-39995796-source.tar` is SHA-256
`23374465684a78bba2fb1c3e5264cfa21ee17d932612d0f4cec12a3c44e17663`
(10,188,800 bytes; 558 regular files), from that exact commit and excluding
`docs/private-ai/` and `docs/private-checkpoints/`.
The regenerated inventory SHA-256 is
`11091d7be26134170229d86e552b643a1c746d9de2b835cd459063df0f615af7`;
the matching source-bound supplemental evidence SHA-256 is
`4bee37c126578d537f4c37966aa24b0123ef40f0e2ff11a4234828546a43d726`.
It covers 479 package identities and 462 compiler-artifact identities, with
one unresolved corresponding-source delivery and applicable licence/notice
review obligation. The evidence establishes provenance and notice-text
identity only, not legal clearance or an X Ode release. Do not publish the
draft or source archive before the asset is attached and the owner makes the
publication decision.

The issue #37 diagnostic candidate is built from
`9c9d85b24a701c5b1c1932a8eda3391d9d31b81e`
(tree `f668516a8efaf15850a29eed2a486d22818975d1`), a bounded change on that
installed producer. Its corresponding-source archive is
`xodus-cli-9c9d85b2-source.tar`, SHA-256
`d54cbf1fb8b1372491b477182a043b5d8315d0a896dc6049f55b523502e1046a`
(10,209,280 bytes; 558 regular files), with the same private-directory
exclusions. The change adds finite sign-in failure classes, not successful
sign-in, gameplay, distribution or legal clearance.
The signed CLI is SHA-256
`e957ef375bf026235d5db68f6a272ca3cdcf1ea139e1751d81b06233e7a6fe1a`
(30,995,552 bytes), and its manifest is
`0ca09ff03fd3607ce25df5877c2c4c04255f6e57833a088ba10d240ec3b32eb0`.
The helper is unchanged. The regenerated notice inventory is
`4ed645219442726d1bbfe219c2142c2c4135ae654649e3f47277527b6ae94b16`;
its matching supplemental evidence is
`63ba7b48529ffaa064bf7ca7b33fb469f429bd77d99367dcee3ec96d30e8e21f`.
It retains the existing unresolved corresponding-source delivery and applicable
licence/notice review obligation.

For r7, the bound metadata identifies 479 packages, 462 with compiler artifacts,
and 472 package-level licence declarations. The seven undeclared manifests are
`eappx` and the six Xodus workspace crates; their repository licence texts are
included separately rather than inventing a package SPDX grant. `eappx` has an
MIT root notice, and the workspace has the GNU GPL v3 root text.
`option-ext@0.2.0` and `webpki-roots@0.25.4` declare MPL-2.0, requiring an
appropriate source-delivery review. Thirty compiled packages' published archives
contain no standalone notice text; their exact names/versions remain explicit
in the generated inventory rather than being replaced with generic templates.
The reviewed r7 supplemental inventory recovers 26 of those packages' texts
from public upstream licence files at the archives' exact VCS revisions, with
each file checked against its Git tree blob identity. The remaining four
standalone-text gaps are `cms@0.2.3`, `system-configuration-sys@0.5.0`,
`xmlserde@0.7.2` and `xmlserde_derives@0.7.2`. The first and last two exact trees
have no applicable standalone licence file; the exact
`system-configuration-sys` revision was unavailable from its public source.
Declared SPDX expressions remain recorded, not confused with absent grants.
The independently compared inventory has 479 package identities, 462 compiled
identities. The notice-only successor contains 327 content-addressed texts,
excluding two `copying.rs` implementation/test files falsely matched by a
`COPYING` prefix. Its r7-only SHA-256 is
`f2ae3d1f5f00687d6cefb7d75afb65235cf2b0d04d3e489728a1d49951af5a01`.
That digest is completeness evidence, not rights clearance or a successor
producer approval.
The helper's `scripts/windows/window-monitor.c` is compiled with MinGW GCC and
`-luser32`; exact CRT/compiler-support-library provenance and applicable notices
or exceptions, and Rust standard-library/compiler-runtime obligations, remain
separate from Cargo package metadata.

Supply the prepared directory with `--producer-notices` and an independently
reviewed `--producer-notices-sha256` to either builder.
Before app signing, the inventory and content-addressed notice texts are copied
to `Contents/Resources/ProducerNotices`; producer source and CLI/helper hashes
must match. The distribution manifest binds the inventory, checks every notice,
and retains exact unresolved obligations. An inventory is not legal clearance.
The distribution gate also requires the external approved digest: an inventory
cannot remove package records or obligations and approve its own replacement
hash, even if a new app signature seals that reduced inventory.

The main Xodus executable is not raw-hash-bound in this in-bundle manifest:
macOS signing rewrites its Mach-O signature after resource assembly. Post-sign
preflight verifies the app's code signature, cdhash, signing identifier, team
and expected certificate instead. Other signed components remain hash-bound.

Optional Python runtimes, launch-association capsules and separately installed
credential-broker references have independent source/licence/rights entries.
Python's exact file manifest and archive pin are revalidated; the broker entry
identifies a separately installed payload, not a bundled executable. Clearing
the four base components cannot clear these optional obligations. Unmapped
files, executables and runtime directories fail package preflight; known
non-code resources cannot conceal executable headers.

### Runtime paths versus evidence paths

In source `2794e68`, `engine-defaults-v1.json`'s
`bindings[].registryPath` is consumed by default engine inspection.
`NativeLaunchConfiguration.resolveDefault` reads this catalogue even before
saved overrides, so existing runtime discovery alone cannot make the legacy
default route portable. A reviewed consumer contract is needed; do not rewrite
the admitted recipes or copy user-installed engines into a release.
The custom-engine opaque selection ID is a separate user-state route, not
portability proof for existing registry-bound admissions.

Candidate `profiles[].game_dir` and `installation_evidence` fields are ignored
by `NativeCandidateLaunchCatalogue.Row`; it validates the actual installed game
folder. Local paths in `title-runtime-v1.json` evidence/scan fields and
`mac-game-evidence-v1.json` screenshots are provenance, not engine discovery.
They still need a privacy/publication review: the current conservative
distribution gate rejects development-machine references even in provenance.
Retaining them does not justify calling them runtime lookup failures, and
editing hash-bound policy merely to satisfy a scanner is not admission.
