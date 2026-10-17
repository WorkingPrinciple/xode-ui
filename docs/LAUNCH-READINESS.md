# X Ode launch readiness

## Private source-adoption addendum (2026-10-17)

The draft integration adopts the complete native app history through
`784dedf517845e0caf4cdedcd032444cddaa3d2a` (tree
`bb986a806defa63d07a9c3f58e33a19841601c03`) while preserving the seven
documentation/bootstrap commits through `7d627d60288b310310ae9bf2487f4d1f3425b922`.
The documentation-only `main` description below is the **2026-10-12 snapshot**,
not a description of this integration checkout or proof that adoption is merged.
No default-branch change or release is performed.

The [issue ledger](ISSUE-LEDGER.md) and [game-test ledger](GAME-TEST-LEDGER.md)
are imported byte-for-byte from `eb07537dc9cd1bead01780b66366f1664492eb22`.
They record later parent-observed signed-package identity, native UI/account
recovery and Play/Stop evidence. This source-adoption lane did not repeat any
runtime, account, Keychain, signing, installation or gameplay action.
Management authentication, PC-library entitlement and game-service identity
remain separate.

Unchanged full-Xcode 27 [run 39013367846](https://github.com/dragoshont/xodus-macos-app/actions/runs/39013367846)
passed for exact `784dedf`, including real shipping XCTest, native checks and SVG
reproduction. That result does **not** certify the integration commit; its fresh
run and exact head are reported separately in the adoption PR.
No app code, tests, package manifest, tools, design or workflow content changes
are intended by the merge.

Component acquisition, backend-source/build provenance and legal/redistribution
holds [#28](https://github.com/dragoshont/xodus-macos-app/issues/28) and
[#38](https://github.com/dragoshont/xodus-macos-app/issues/38) remain unresolved.
Preserved GPL/SPDX/notices do not clear third-party rights. No component
binaries, Wine/CrossOver/Windows code or XCurl adapter are added. Fresh-Mac,
distribution/signing/notarization, exact paired-input and title-specific
qualification requirements below remain independent. There is no public release
or multiplayer acceptance claim.

## Historical recovery snapshot (2026-10-12)

Evidence snapshot: **2026-10-12**. This documentation pass read immutable source,
tests and GitHub metadata; it did not sign, package, install or launch anything.
The owner's [immutable recovery handoff](https://github.com/dragoshont/xodus-macos-app/blob/00cff3d624ee4ce40c308128eccd3e9d213e0433/docs/PAUSE-HANDOFF.md)
records bounded read-only recovery and selected-source backup with no game runs. Its recovered identities and
historical observations below are attributed, not freshly reproduced here.

## Which version?

| Role | Exact source / evidence | What it establishes |
| --- | --- | --- |
| Historical reference | [`02e67f8`](https://github.com/dragoshont/xodus-macos-app/commit/02e67f89c01dbd9ea3549a1fc628adbfcfbad29a) | Package and deployment receipts recovered; superseded by later `fac58d6` deployment evidence, not identified as current |
| Later historical deployment | [`fac58d6`](https://github.com/dragoshont/xodus-macos-app/commit/fac58d6f501c356a0e763d397263e5a0a30b3477), [successful native-fixtures CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/38065402103) | Package and deployment receipts recovered; later installation supersedes the early Quit hold. CI success independently read |
| Current app | Generic version 0.2.0/build 2 | Current executable/source identity unestablished; Info.plist alone cannot identify its commit |
| Newer development source | [`87110738`](https://github.com/dragoshont/xodus-macos-app/commit/87110738e4d90449b748f3a8a809f407d41b830f) on `dragoshont-xodus-app-foundation` | Separate from historical deployments; not a release or current-install receipt |
| Backend source | `87ccc73af0811e7bc007a2ad97035d39e8eed96b`, branch `private/ai-hogwarts-runtime`, plus dirty working script | 165 selected working-source files preserved in a private local Windows archive, all hashes verified. Not a full build closure or remote publication: provenance findings need human review. Historical `a3036bf` full SHA/ancestry unresolved |
| `main` / documentation branch | Initial `45a1596` ancestry plus documentation-only updates | Not the Swift application source; never use the documentation checkout as a packaging input |

GitHub reports [#12](https://github.com/dragoshont/xodus-macos-app/pull/12)
(M10), [#13](https://github.com/dragoshont/xodus-macos-app/pull/13) and
[#15](https://github.com/dragoshont/xodus-macos-app/pull/15) (M1/M3), and
[#14](https://github.com/dragoshont/xodus-macos-app/pull/14) (M7) merged on
2026-10-10 into **the foundation branch, not `main`**. Historical dashboard
"open" labels are stale. These merges do not establish an installed package,
backend protocol support, live queue acceptance or available-version coverage.

## Qualification boundaries

Pinned [game-operation checks](https://github.com/dragoshont/xodus-macos-app/blob/fac58d6f501c356a0e763d397263e5a0a30b3477/Sources/XodusPreview/GameOperationChecks.swift)
exercise synthetic script receipts, progress, cancellation, support checks and
Stop results. [Library checks](https://github.com/dragoshont/xodus-macos-app/blob/fac58d6f501c356a0e763d397263e5a0a30b3477/Sources/XodusPreview/LibraryAccessChecks.swift)
keep imported installation, ownership and subscription evidence distinct.
[Shipping checks](https://github.com/dragoshont/xodus-macos-app/blob/fac58d6f501c356a0e763d397263e5a0a30b3477/Tests/ShippingChecks/ShippingChecks.swift)
assert neutral startup and dependency/experimental boundaries. These are not
retail gameplay or completed-release percentages.

No Man's Sky single-player is owner-confirmed on the CrossOver-backed path.
Pinned [historical acceptance notes](https://github.com/dragoshont/xodus-macos-app/blob/fac58d6f501c356a0e763d397263e5a0a30b3477/README.md)
also record bounded Lara install/repair/uninstall/main-menu and Hogwarts
Play/Continue Playing observations; they do not certify the current app or all
games. Celeste's recorded unsupported-package result is **not** success.
Cuphead, UWP/EAppx and online multiplayer have no success claim here.

Both recovered package receipts agree on the bundled management CLI and frozen
broker hashes/byte counts recorded in the recovery handoff. The separately read
current service hash is **not** certified against those historical receipts or a
backend build commit. The NMS registered launcher digest and delegation were
recovered: it uses `Runtime-NMS-BQVQTL3PCH05-76`, not the generic runtime.
Its current script bytes are not bound to the historical successful run.
Prior Cuphead experiments modified the same CrossOver vendor tree used by NMS;
historical restoration receipts do not establish isolation or fresh NMS
qualification. Reconfirm the exact runtime before release acceptance.

## Release checklist

| State | Gate | Required evidence |
| --- | --- | --- |
| Verified source evidence | Pinned source exists; native-fixtures CI succeeded; minimum OS is declared | Immutable commit, CI run and manifests linked above |
| Recovered owner evidence | Both historical packages/deployments, management CLI/broker pins, current service hash and NMS launcher delegation | Immutable recovery handoff; not current-app identity or backend/service/game-success pairing |
| Historical owner report | NMS single-player; bounded earlier UI/game acceptance | Keep title, package/runtime version and observed mode separate from current candidate qualification |
| Pending | Reproducible backend and exact package pair | Selected working source is backed up locally. Resolve historical `a3036bf` identity; map source/build to the service, establish full build closure and paired-inputs evidence, and review provenance before remote upload |
| Pending | Current app identity and safe future installation | Identify installed executable/source; do not reinstate the superseded Quit blocker. Future replacement still needs normal Quit, no gameplay/mutation, preserved rollback, authorization and installed-byte verification |
| Pending | Fresh-Mac prerequisites and UX | Clean Apple Silicon Mac: qualify supported OS, licensed CrossOver, runtime setup, sign-in/Keychain consent, empty/error/recovery states and all advertised operations |
| Pending | Signing, notarization and distribution | Developer ID/notarization and Gatekeeper evidence for the exact artifact, component/license/source manifest, reviewed installer/update/rollback channel; a local signed candidate is insufficient |
| Pending | Title-specific launch qualification | Authorized entitled MSIXVC install, NMS single-player start/exit and saves; separately verify Play/Stop, update/repair/uninstall and cancellation on the exact release pair |
| Pending | Publication hygiene and visuals | Review exact source/archive for secrets, real-account captures and proprietary runtime/game binaries; obtain a sanitized current UI capture with consent |

The README embeds only the inspected **historical Library fixture mockup** with
original fictional art. No usable current live screenshot has been established.
No sensitive content was found in that image; the exact release archive has
**not** been audited. Do not publish private scripts, credentials, entitled game
packages or third-party runtime binaries without an explicit redistribution
review. No release, tag, runtime rename or feature gate is created by these docs.

Backend owner: [regrouping and paused scope](https://github.com/dragoshont/xodus-macos/blob/dragoshont-heroic-xbox-integration/docs/xodus/regrouping.md)
and [publication precautions](https://github.com/dragoshont/xodus-macos/blob/dragoshont-heroic-xbox-integration/docs/xodus/publication.md).
