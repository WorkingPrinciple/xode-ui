# Owned game-root migration

`tools/migrate_game_root.py` is an operator library, not an automatic startup
migration. COR180 authorizes the exact `~/Games/Xodus` to `~/Games/Xode`
transaction only after the reviewed app successor supports the new default and
preserved NMS binding. The runtime owner supplies a fresh process/lock
quiescence check; no process termination or restart is implicit in this tool.

`prepare(old, new, files, partial, stage)` snapshots immediately current small
metadata files and modes into a new owner-only evidence directory outside both
roots. The first file must be `installed-games.json` with kind `registry`;
only each record's `folder` value is mapped. Kind `resumable` maps only each
retry record's `destination`. Kind `json` structurally maps exact old-root path
values in separately reviewed live launch profiles, never keys or substrings.
Kind `launcher` changes only the reviewed unquoted
`export XODUS_GAME_FOLDER=` assignment; any remaining old-root reference fails.
Do not include historical receipts, credentials or prefixes in the file set.

`apply(stage, quiescent)` revalidates snapshots, partial and immediate child
identities, absence of an active operation journal and the destination, and
checks quiescence again immediately before the move. macOS `renamex_np` with
`RENAME_EXCL` refuses overwrite even if a destination appears after preflight.
One same-volume rename includes hidden sibling locks, partials and caches.
Persisted file updates are atomic and preserve modes. Account binding, UUIDs,
engine choices and unrelated custom paths are not rewritten.

On a handled failure the tool restores only its own changed files after
checking they still contain its expected output, then reverses its root move
only if the old root remains absent. It checks original bytes and partial/child
identities and stays quiescent. A crash or rollback conflict requires inspection
of the durable `migration.json` and snapshots; never blindly replay or overwrite
an external write. There is no automatic app restart or download Resume.
Root migration does not recover disk space or prove backend byte resume.

Run `python3 tools/check_game_root_migration.py` for isolated same-volume,
collision, exact-boundary, external-change and failure/rollback checks.
Final acceptance additionally requires the reviewed installed successor,
unchanged registry/retry semantics under inverse mapping, no recreated old
root, and explicit coordinator handoff before any game-owner relaunch.
