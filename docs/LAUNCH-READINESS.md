# X Ode launch readiness

Evidence snapshot: **2026-10-12**. This documentation pass read immutable source,
tests and GitHub metadata; it did not inspect the installed Mac, sign, package,
install or launch anything. Coordinator observations below are attributed, not
freshly reproduced.

## Which version?

| Role | Exact source / evidence | What it establishes |
| --- | --- | --- |
| Installed reference | [`02e67f8`](https://github.com/dragoshont/xodus-macos-app/commit/02e67f89c01dbd9ea3549a1fc628adbfcfbad29a) | Coordinator reports this installed app; source commit exists. No current install observation here |
| Signed candidate | [`fac58d6`](https://github.com/dragoshont/xodus-macos-app/commit/fac58d6f501c356a0e763d397263e5a0a30b3477), [successful native-fixtures CI](https://github.com/dragoshont/xodus-macos-app/actions/runs/38065402103) | CI success independently read; signed-package status is coordinator-reported. Installation blocked by the running app's normal-Quit refusal |
| Newer development source | [`87110738`](https://github.com/dragoshont/xodus-macos-app/commit/87110738e4d90449b748f3a8a809f407d41b830f) on `dragoshont-xodus-app-foundation` | Separate from the installed reference and candidate; not a release or install receipt |
| Reported backend | `a3036bf` in `dragoshont/xodus-macos` | GitHub commit lookup returned 422/no commit. Not remotely reproducible; obtain the exact published source and package receipt before pairing |
| `main` / this docs branch | `main` remains initial `45a1596`; this branch adds only documentation | Not the Swift application source; never use this README branch as a packaging input |

GitHub reports [#12](https://github.com/dragoshont/xodus-macos-app/pull/12)
(M10), [#13](https://github.com/dragoshont/xodus-macos-app/pull/13) and
[#15](https://github.com/dragoshont/xodus-macos-app/pull/15) (M1/M3), and
[#14](https://github.com/dragoshont/xodus-macos-app/pull/14) (M7) merged on
2026-10-10 into **the foundation branch, not `main`**. Historical dashboard
"open" labels are stale. These merges do not establish an installed package,
backend protocol support, live queue acceptance or available-version coverage.

## Qualification boundaries

Candidate [game-operation checks](https://github.com/dragoshont/xodus-macos-app/blob/fac58d6f501c356a0e763d397263e5a0a30b3477/Sources/XodusPreview/GameOperationChecks.swift)
exercise synthetic script receipts, progress, cancellation, support checks and
Stop results. [Library checks](https://github.com/dragoshont/xodus-macos-app/blob/fac58d6f501c356a0e763d397263e5a0a30b3477/Sources/XodusPreview/LibraryAccessChecks.swift)
keep imported installation, ownership and subscription evidence distinct.
[Shipping checks](https://github.com/dragoshont/xodus-macos-app/blob/fac58d6f501c356a0e763d397263e5a0a30b3477/Tests/ShippingChecks/ShippingChecks.swift)
assert neutral startup and dependency/experimental boundaries. These are not
retail gameplay or completed-release percentages.

No Man's Sky single-player is owner-confirmed on the CrossOver-backed path.
Candidate [historical acceptance notes](https://github.com/dragoshont/xodus-macos-app/blob/fac58d6f501c356a0e763d397263e5a0a30b3477/README.md)
also record bounded Lara install/repair/uninstall/main-menu and Hogwarts
Play/Continue Playing observations; they do not certify this candidate or all
games. Celeste's recorded unsupported-package result is **not** success.
Cuphead, UWP/EAppx and online multiplayer have no success claim here.

## Release checklist

| State | Gate | Required evidence |
| --- | --- | --- |
| Verified source evidence | Candidate exists; native-fixtures CI succeeded; minimum OS is declared | Immutable commit, CI run and manifests linked above; no inferred install status |
| Historical owner report | NMS single-player; bounded earlier UI/game acceptance | Keep title, package/runtime version and observed mode separate from current candidate qualification |
| Pending | Reproducible backend and exact package pair | Resolve `a3036bf`; record source/tree, engine/helper hashes, versions and independent admission receipts |
| Blocked | Safe candidate installation | Running app refuses normal Quit. Resolve without force Quit; freshly confirm no gameplay/mutation, retain rollback, then obtain authorized replacement and installed-byte verification |
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
(publication pending at this snapshot; reserved destination).
