# X Ode 0.2.0 (Beta) launch readiness

Snapshot: **2026-10-26**. This records the interim build and source gates
observed for this candidate. It is not a release qualification, notarization
record or gameplay approval.

## Candidate identity

| Item | Verified state |
| --- | --- |
| Product | X Ode 0.2.0 (Beta), build 502 |
| App source | `a6a45549550471bf8d8be92aee98eb37d8fce35d`; tree `73307652fdd8149a89f2b778a48a9913041146ff` |
| App bundle ID | `com.workingprinciple.xode.development` |
| Signing identifier | `com.workingprinciple.xode` |
| Signature | Developer ID Application, team `M62Z4M5EUY`; deep strict verification passed |
| Producer pair | Calimocho -04 source `99e20addf88932de7796fc966fe09e00b71e4981`, tree `7f9e8cc5…` |
| Bundled CLI | `ae36f62c63ffbd371ce104559c29d2a5f1c8fa5170de5bc83e520ce9516defc9` |
| Local installation | Installed over the existing development candidate after the explicit lane-clear and Wine guard; the existing rollback copy was retained |
| Account state | A read-only Account status check confirmed the saved sign-in; no sign-in or sign-out action was taken |
| Distribution | No DMG or notarization was produced for this interim candidate |

The signed app was launched from its existing development location. Its product
name changed to **X Ode**; the bundle ID and signing identifier remained
unchanged. The local install does not establish a public release or a clean-Mac
installation result.

## Product and runtime boundaries

Calimocho is the default engine and has an in-app installation flow. CrossOver
is optional and detected when installed; detection does not establish license
status or game compatibility. The project supports a DMG installer workflow,
but this snapshot has no generated or notarized DMG.

The -04 Forza Horizon 6 title-screen check did not establish gameplay
qualification. “Sign In Required” also occurred with the old -01-fh6 engine,
so account state remains a separate blocker. Continue and free roam were not
verified. Do not infer title qualification from the installer, engine pin,
account status or synthetic checks.

The app source now uses an explicit runtime resource allowlist. The DMG
packaging path emits a hash-bound `RESOURCE-INVENTORY.json`; QA/inspection
queues, package-only receipts and machine-local proof paths are not allowed in
the distributed app bundle. Their required admission hashes remain in the
package receipt. The inventory lists the approved NMS developer-local registry
binding in `engine-defaults-v1.json` as the sole explicit path exception.

## Verification and remaining gates

On the exact interim source, the shipping-pair checks (64), beta-package
checks, release-candidate tests (18), local-candidate tests (7), management
checks (10,910), game-operation checks (1,310), preview checks (454), auth-host
checks (152) and credential checks (19) passed. The preview checks require the
configured UX render directory. The broader `sh tools/check.sh` run retained a
separate native-session failure:
`e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options`,
code 13 (857 checks, one failure). The native-session issue is not reported as
fixed by the packaging or documentation changes.

| Gate | Status | Boundary |
| --- | --- | --- |
| Signed interim candidate | Verified | Build 502; Developer ID signature passed deep strict verification |
| Local in-place deployment | Verified | Existing app identity preserved; rollback copy retained |
| Read-only account status | Verified | Saved sign-in was confirmed; no credentials were changed |
| Resource sanitization | Source gate | The allowlist and path/QA checks apply to the next build, not the installed interim build |
| DMG and notarization | Pending | No DMG or notarization for the interim candidate |
| Fresh-Mac installation | Pending | Local installation does not establish first-run behavior or Gatekeeper acceptance |
| Forza Horizon 6 gameplay | Not qualified | Title screen only; sign-in blocked Continue and free roam |
| Install/cancel/resume acceptance | Pending | Requires an eligible uninstalled test target |
| Broader gameplay and multiplayer | Pending | No general compatibility or online-multiplayer claim |

The README mockup remains historical UI artwork, not a current live capture.
Third-party runtime, game-package, redistribution-rights and corresponding-source
obligations remain separate release gates; source changes or a local signature
do not satisfy them.
