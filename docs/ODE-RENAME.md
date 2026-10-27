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
| C symbol `xodus_process_start` | `ode_process_start` |
| Bundle `io.github.dragoshont.xodus(.development)` | `com.workingprinciple.xode` |
| CLI package `com.odetox.xodus-cli` | `com.workingprinciple.ode-cli` |
| Executable and icon `Xodus` | `Ode` |
| CLI in bundle `Contents/Resources/XodusEngine/xodus-cli` | `Contents/Resources/OdeEngine/ode-cli` |
| Accessibility IDs `xodus.*` | `ode.*` |
| Defaults keys `Xodus.*` | `Ode.*` (one-time import of old values) |
| Environment and compile flags `XODUS_*` | `ODE_*` (suffix unchanged; the app emits only new names) |
| Backend artefacts `xodus-service`, `xodus-window-monitor.exe`, `.xodus-streaming.msixvc` | `ode-service`, `ode-window-monitor.exe`, `.ode-streaming.msixvc` |
| Private repos `xodus-macos-private-ai`, `xodus-winrt-shims`, `xodus-provenance` | `xode-macos-private-ai`, `xode-winrt-shims`, `xode-provenance` |

Data roots, socket and Keychain services follow the backend contract: `~/Library/Application Support/Ode to X/{State,CLI,EdgeCDP,Remote}`, `/tmp/ode.sock`, `Ode Service`, `Ode Management Service`. Old Keychain items are read only, for one release.

## Compatibility

Every legacy literal the app still needs sits in one file, `Sources/OdeCore/LegacyCompatibility.swift`, marked for removal after the next release. It covers old data roots (read fallback), old Keychain services (read only), the old defaults domain and keys (one-time import, old values never deleted) and translation of legacy recipe keys. Moving to a new bundle ID resets macOS privacy (TCC) grants; the app asks again on first use.

## Grep gate

`tools/check_legacy_name.py` fails on any case-insensitive match in tracked paths or contents outside these exceptions:

1. `Sources/OdeCore/LegacyCompatibility.swift`
2. `tools/check_legacy_name.py` (the gate)
3. Upstream attribution and links to the inherited public fork `WorkingPrinciple/xodus-macos` and upstream `xodus-gaming/xodus` (matched by exact line pattern, not whole file)
4. Immutable archives under `design/archive/`
5. Content-addressed pinned producer artefact names until a renamed producer is pinned

Code inherited from upstream forks is out of scope and is not in this repository.
