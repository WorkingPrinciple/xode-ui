# Ode rename (REQ-150)

Lane L23 renames the legacy codename to Ode in this repository. Parent REQ-146 (shared contract, data migration) is owned by the backend lane; this repo consumes that contract and does not redefine it.

## Inventory before the rename

Base: `dragoshont-mvp-integration` at `c67d77a2`. Case-insensitive scan of tracked files.

| category | product source | tests/fixtures | scripts/CI | docs | archive | lines | files |
|---|---|---|---|---|---|---|---|
| J upstream/fork attribution | 6 | 7 | 1 | 48 | 0 | 62 | 16 |
| K renamed private repo refs | 0 | 0 | 0 | 2 | 0 | 2 | 2 |
| C bundle/package IDs | 34 | 1 | 15 | 11 | 0 | 61 | 37 |
| H Keychain services | 3 | 1 | 0 | 0 | 0 | 4 | 3 |
| G on-disk/OS paths | 45 | 62 | 5 | 42 | 0 | 154 | 42 |
| I backend artefact/wire names | 72 | 61 | 66 | 27 | 4 | 230 | 67 |
| F env/compile flags | 100 | 69 | 13 | 34 | 0 | 216 | 66 |
| D accessibility IDs | 257 | 7 | 24 | 0 | 0 | 288 | 40 |
| E defaults/KVO keys | 54 | 53 | 11 | 0 | 0 | 118 | 39 |
| B Swift module/target/type/C symbol | 146 | 125 | 141 | 108 | 0 | 520 | 174 |
| M product prose / other | 74 | 81 | 89 | 116 | 19 | 379 | 116 |

Total matching lines: 2034; files: 290
Tracked paths with xodus in name: 219

Categories are assigned first-match in the order listed.

## Mapping

| Old | New |
|---|---|
| Swift package `XodusAppFoundation` | `OdeApp` |
| Targets, folders and types `Xodus…` | `Ode…` |
| C symbols `xodus_process_start`, `xodus_process_matches` | `ode_process_start`, `ode_process_matches` |
| Bundle `io.github.dragoshont.xodus` (+ `.development`, `.qualification`, `.credential-broker`) | `com.workingprinciple.xode` (same suffixes) |
| CLI package `com.odetox.xodus-cli` | `com.workingprinciple.ode-cli` |
| Executable and icon `Xodus` | `Ode` (user-visible `.app` names unchanged) |
| CLI in the bundle `Contents/Resources/XodusEngine/xodus-cli` | `Contents/Resources/OdeEngine/ode-cli` (helper `ode-window-monitor.exe`) |
| Accessibility IDs `xodus.*` | `ode.*` |
| Preference keys `Xodus.*` / `xodus.*` | `Ode.*` / `ode.*` (one-time import of old values; `windowsProfileUnverifiedPrefixes.v1` merged) |
| Environment and compile flags `XODUS_*` | `ODE_*` (suffix unchanged; the app emits only new names) |
| Generated run IDs `xodus-<UTC>-<hex>` | `ode-<UTC>-<hex>` (old IDs still read) |
| Data roots `Xodus`, `XodusCLI`, `XodusEdgeCDP`, `XodusRemote` under Application Support | `Ode to X/State`, `Ode to X/CLI`, `Ode to X/EdgeCDP`, `Ode to X/Remote` |
| `Library/Logs/XodusRemote`, `Library/Caches/Xodus` | `Library/Logs/Ode to X/Remote`, `Library/Caches/Ode to X` |
| Game library folder `~/Games/Xodus` | `~/Games/Xode` (old folder still discovered; recorded evidence keeps its paths) |
| Keychain service `Xodus Library` | `Ode Library` (COR-310) |
| Private repos `xodus-macos-private-ai`, `xodus-winrt-shims`, `xodus-provenance` | `xode-macos-private-ai`, `xode-winrt-shims`, `xode-provenance` |

## Compatibility

This repository follows the backend compatibility manifest `docs/contracts/ode-identity-compat-v1.json` in WorkingPrinciple/xode-macos-private-ai at `a272b1d7f10ccf0aa32936e24551098b9c7cd02e`. New writes use canonical names only: schema IDs `urn:ode:management:1.0`, `urn:ode:runtime-provider-configuration:1` and `urn:ode:private-native-auth-host:1`; markers `.ode-streaming(-tmp).msixvc`; sidecars `.<name>.ode-lifecycle.lock` and `.<prefix>.ode-engine-owner.json`; run IDs `ode-…`; runtime scripts `private-ode-*`. The app uses no license socket.

Legacy names live in one file per language:

- Swift: `Sources/OdeLegacyCompatibility/LegacyCompatibility.swift` (its own dependency-free target, so the credential broker can use it).
- Python: `tools/legacy_compatibility.py`.

They hold:

- **One stable protocol value, kept for good:** the v1 account-hash domain (COR-314). Changing it would change existing account identities.
- **Read-only names from before the rename, removed after the next release:** a management schema ID normalised to the canonical one before validation; the old lifecycle-lock and engine-owner sidecar names; old run IDs; the old preference domain and keys (imported once; existing values win, except that the Play-hold marks `Xodus.windowsProfileUnverifiedPrefixes.v1` (added in 694) are merged into `Ode.windowsProfileUnverifiedPrefixes.v1` so no marked prefix can play; prefix paths under an old data root are rewritten to the new root; the old domain is never changed); the old `Library` Keychain service (copied forward on first use by the broker or the direct store, never changed or deleted this release, and ignored after sign-out); the old bundle IDs (so an old copy still running blocks a new one); and the CLI location inside an app installed before the rename.
- **Persistent data identity, kept until an explicit owner decision, never on a timer:** both in-prefix save-folder families (`LocalSaves`, `ContainerSaves`, `CloudSnapshot`), never moved or merged (COR-316), the old game library folder name under `~/Games` and at volume roots, and the package marker file installed games keep on disk (`.xodus-streaming.msixvc`), which the backend reports in install-inventory package records.
- **Python only:** inherited upstream crate and binary names the packaging tools build (`xodus`, `xodus-cli`, `xodus-service`), the Windows helper file name the producer still emits (`xodus-window-monitor.exe`, also from the renamed producer `285696f9`; the app bundle renames it on copy), and the signing identifiers of an installed pre-rename app, which only the read-only check of that app accepts.

The app does not read data from the old roots. If an old State or CLI root is still a real folder and its new root is missing, the data move has not run. If an old root is still a real folder and its new root exists too, the data is in two places, a state the move contract does not define. In both cases the app shows an alert and quits without changing anything. An old root that is the move's alias (a symbolic link) counts as moved. Moving to a new bundle ID resets macOS privacy (TCC) grants; the app asks again on first use.

## Grep gate

`tools/check_legacy_name.py` (run by `tools/check.sh`) fails on any case-insensitive match in tracked or new paths and text outside these exceptions:

1. The two adapters above.
2. The gate itself, this record, and `.gitleaksignore` (fingerprints of historical commits).
3. Backend contract schema copies (now carrying canonical IDs; listed so a future resync cannot silently reintroduce old names elsewhere).
4. Immutable archives under `design/archive/`, and historical evidence that hash-locked receipts refer to: the tested-games ledger (`docs/GAME-TEST-LEDGER.md`, `docs/game-test-ledger-state.json`), the compatibility catalogue `game-compatibility-v1.json` (SHA-256 `d3ff0ff0…`) and the four QA queue evidence files it was built from. The ledger state and the catalogue are byte-identical to 694; the generated `GAME-TEST-LEDGER.md` differs only in line 11, the catalogue's source path (`Sources/OdeManagement/…`), and its SHA-256 lock `d3ff0ff0…` is unchanged. The gate pins those four by Git blob SHA-1 (identical to 692 and 694), so any edit to them fails it.
5. Spans, not whole lines: the upstream repository `xodus-gaming/xodus`, the inherited public fork `WorkingPrinciple/xodus-macos` and links into it, and links to a file at a pinned commit in a WorkingPrinciple or dragoshont repository. Only the span is removed; the rest of the line is still checked. On a line with such a span, the upstream project's own name `Xodus` (the bare word) is also allowed. The gate runs a self-test of lines that must fail, including a pinned link followed by another legacy name (708fb8ae n1).
6. Tokens anywhere: pinned producer archive names `xodus-cli-<…>-source.tar`, and the inherited upstream Wine name `XODUS_XBL_ONLINE`.
7. In launch recipes only: the runtime-pin-pending environment names above, and the runtime's pre-rename debug channels `+xodus_user` and `+xodus_package`, passed beside `+ode_user`/`+ode_package` for one release so either runtime version traces (COR-337).

Code inherited from upstream forks is not in this repository. The tested-games ledger, its run IDs and the catalogue evidence keep their recorded names. Other historical documents use the new names; the originals remain in Git history.

## Rollout

- Install the renamed apps only after the data move has run, with every X Ode app quit.
- Remove or replace the pre-rename app bundles (bundle IDs `io.github.dragoshont.xodus*`) when installing the renamed ones. A renamed app refuses to open while an old copy is running, but an old copy left installed keeps writing to the old roots, which become aliases after the move.
- Packaging pairs only with a reviewed renamed producer. `tools/shipping_pair.py` sets `PRODUCER_RENAMED = True` since the renamed producer `285696f9` was pinned (review bf205a75), and every packaging path (`build_app.sh`, `build_local_candidate.py`, `refresh_local_candidate.py`, `release_candidate.py`, `package_beta.py`) calls `require_renamed_producer()`. It also refuses while the pins still name a pre-rename producer (`PRE_RENAME_PRODUCERS`, even with the flag set), and rejects a producer contract carrying pre-rename schema IDs wherever the contract is read (local candidate build, refresh, and release through refresh).
- The renamed apps sign with new identifiers (`com.workingprinciple.xode*` instead of `io.github.dragoshont.xodus*`; Team ID unchanged). Pre-rename Keychain items whose access lists name the old identifier therefore ask once, when the app or credential broker first copies them forward. Together with the privacy (TCC) prompts, this needs the owner's acknowledgement before install.
- At startup the data-move check runs before the instance lock, because the lock lives under the new State root and creating it first would split unmoved data.

## Pairing

The app pairs with the renamed producer `285696f9` (REQ-161), which reads `ODE_*` first and the old names for one release. Recipes and launch configuration that hard-code data paths use the new roots, so the data move must run before the first launch.

Two kinds of environment name keep the old spelling, and both live only in the Swift compatibility file and the launch recipes:

- `XODUS_XBL_ONLINE` is read by upstream Wine's builtin xgameruntime and is never renamed.
- `XODUS_PRIVATE_RUNTIME_COM_STA`, `XODUS_PRIVATE_CALLER_OWNS_COM` and `XODUS_PRIVATE_LOCAL_SAVES` are runtime-pin-pending: the app's pinned runtime pair predates `f8092bb` and reads only these names. They move to `ODE_*` when a runtime at or after `f8092bb` is pinned (no dual writes).

## Follow-ups

- Before a public release, the data move must run inside the app or its installer, not only as a coordinator-run step. Until then the app refuses to start while an old State or CLI root is still a real folder (accepted by coordinator 2 for the coordinated migration only).

## Commits

The reviewed rename on top of integration 692 is `9182a89c` (mechanical pass) and `ec3c1414` (compatibility file, contract alignment and fixes), followed by the producer pairing `001bd284`.
