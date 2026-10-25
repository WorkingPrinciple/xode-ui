# Licensing boundaries

SPDX-License-Identifier: GPL-3.0-only

The user explicitly selected **GNU General Public License version 3** for this public app. [LICENSE](../LICENSE) contains the verbatim GNU GPL v3 text, dated 29 June 2007. Original app source, tests, documentation, fixture data, original artwork and mockup/export tooling in this repository are provided under **GPL-3.0-only**, not GPL-3.0-or-later.

The choice is user-directed and matches the reported GPL v3 license at the Xodus fork root. A license template's illustrative "or later" wording does not itself change this app's explicit grant. Source files identify GPL-3.0-only; this document states the grant for original repository material, including generated SVG/PNG artifacts.

The source repository does not bundle proprietary game packages, Microsoft/Apple artwork, paid design assets or fonts. Mockup/system typography uses fonts installed by the operating system. Built app candidates do include the separately built Xodus CLI and Windows monitor; their exact source, dependency licences, notices and corresponding-source obligations must be reviewed independently of this repository's licence. A local signed candidate is not a cleared distribution.

Future runtime components, libraries and assets retain their own licenses. The app license is not a grant to redistribute Wine variants, Microsoft game packages, platform SDK material, trademarks or third-party content. Before packaging, maintain a component/version/license/notice/source-offer manifest and review obligations for the exact paired runtime. GPL app distribution must include the required notices and corresponding source by an appropriate GPL-compliant route.

Signing, notarization, installer/updater channel and the detailed component redistribution review remain release blockers. This foundation makes no legal determination about future consumer APIs or package distribution.

## COR176 package boundary

The source-bound 2794e68 local candidate includes the app, AuthHost, r7 CLI
(producer `01d4cfd625764c2a8ec4d60824ef4f277b30b9e9`), Windows monitor,
management schemas, launch policy, compatibility data, original icon and GPL
text. The AWACY-derived compatibility data retains its MIT notice at
`CompatibilityData/AWACY-LICENSE.txt`. Wine/Calimocho, CrossOver, GPTK,
graphics shims and games are user-installed dependencies, not bundled engines;
their presence on a development machine grants no redistribution rights.

Packaging now allowlists the resources consumed by the management readers and
excludes `next-30-queue.json` and `queue-inspection-v1.json`, which are private QA
inputs rather than runtime policy. Required launch policies are retained
byte-for-byte; removing or rewriting their identity-bound engine paths is not a
safe portability fix. The current `engine-defaults-v1.json` still references
development worktrees, so a portable final distribution remains blocked until
the engine owners provide a reviewed portable binding.

Before any external submission, inventory the exact final app/CLI/helper and
all bundled dependencies with versions, source revisions, licence texts,
copyright notices, corresponding-source delivery and an explicit rights-review
outcome. The app GPL text and source archive do not by themselves establish
complete CLI/helper dependency compliance. No such completed review is claimed
here.
