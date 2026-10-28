#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare and apply an exact, quiescent, reversible game-root migration."""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import stat
import tempfile

from legacy_compatibility import LEGACY_GAME_FOLDER_EXPORT
from shipping_pair import owned_bytes, require


def remap(value, old, new):
    if isinstance(value, str):
        return new + value[len(old):] if value == old or value.startswith(old + "/") else value
    if isinstance(value, list):
        return [remap(child, old, new) for child in value]
    if isinstance(value, dict):
        return {key: remap(child, old, new) for key, child in value.items()}
    return value


def stamp(path):
    info = path.lstat()
    require(not path.is_symlink(), "Linked migration path")
    return {"device": info.st_dev, "inode": info.st_ino, "bytes": info.st_size,
            "mode": stat.S_IMODE(info.st_mode)}


def replacements(data, kind, old, new):
    if kind in ("json", "registry", "resumable"):
        def unique(pairs):
            result = {}
            for key, value in pairs:
                require(key not in result, "Duplicate migration JSON key")
                result[key] = value
            return result
        original = json.loads(data, object_pairs_hook=unique)
        if kind == "registry":
            require(isinstance(original, list), "Expected installed registry list")
            changed = [{**row, "folder": remap(row["folder"], old, new)} for row in original]
        elif kind == "resumable":
            require(isinstance(original, dict), "Expected resumable operation map")
            changed = {key: {**row, "destination": remap(row["destination"], old, new)}
                       for key, row in original.items()}
        else:
            changed = remap(original, old, new)
        return data if changed == original else (json.dumps(changed, indent=2) + "\n").encode()
    require(kind == "launcher", "Unreviewed migration file kind")
    lines = data.decode().splitlines(keepends=True)
    for index, line in enumerate(lines):
        prefix = LEGACY_GAME_FOLDER_EXPORT
        if line.startswith(prefix):
            value = line[len(prefix):].rstrip("\r\n")
            require(value.startswith(old + "/") and not any(c in value for c in "'\"$`\\;"),
                    "Unreviewed launcher assignment")
            lines[index] = prefix + remap(value, old, new) + ("\n" if line.endswith("\n") else "")
    changed = "".join(lines).encode()
    require(old.encode() not in changed, "Unmapped launcher old-root reference")
    return changed


def prepare(old, new, files, partial, stage):
    old, new, partial, stage = map(Path, (old, new, partial, stage))
    require(old.is_absolute() and old.resolve(strict=True) == old and old.is_dir(),
            "Expected canonical existing source root")
    require(new.parent.resolve(strict=True) == new.parent and not new.exists() and not new.is_symlink(),
            "Migration destination collision")
    require(old.stat().st_dev == new.parent.stat().st_dev, "Cross-volume migration forbidden")
    require(partial.is_relative_to(old), "Partial must be inside exact root")
    require(not stage.exists(), "Migration evidence directory already exists")
    require(stage.is_absolute() and not stage.is_relative_to(old)
            and not stage.is_relative_to(new), "Evidence must be outside moved root")
    stage.mkdir(mode=0o700)
    records = []
    for index, (path, kind) in enumerate(files):
        path = Path(path)
        require(path.is_absolute() and path.resolve(strict=True) == path
                and not path.is_relative_to(old), "Noncanonical or in-root persisted reference")
        identity, data = owned_bytes(path, bounded=8 * 1024 * 1024)
        changed = replacements(data, kind, str(old), str(new))
        before, after = str(index) + ".before", str(index) + ".after"
        for name, content in ((before, data), (after, changed)):
            target = stage / name
            target.write_bytes(content)
            target.chmod(0o600)
        records.append({"path": str(path), "kind": kind, "before": before, "after": after,
                        "beforeIdentity": identity, "afterIdentity": {
                            "sha256": hashlib.sha256(changed).hexdigest(), "bytes": len(changed)},
                        "stamp": stamp(path)})
    require(len({record["path"] for record in records}) == len(records), "Duplicate migration file")
    require(records and records[0]["kind"] == "registry"
            and Path(records[0]["path"]).name == "installed-games.json",
            "First persisted reference must be the installed registry")
    plan = {"version": 1, "old": str(old), "new": str(new), "rootStamp": stamp(old),
            "partial": str(partial.relative_to(old)), "partialStamp": stamp(partial),
            "children": {path.name: stamp(path) for path in old.iterdir()},
            "files": records, "state": "prepared"}
    save(stage, plan)
    return plan


def save(stage, plan):
    path = stage / "migration.json"
    temporary = stage / "migration.json.tmp"
    temporary.write_text(json.dumps(plan, sort_keys=True, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def atomic_write(path, content, mode, expected):
    require(path.resolve(strict=True) == path, "Reference ancestry changed")
    original = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    descriptor, name = tempfile.mkstemp(prefix=".xode-migrate-", dir=path.parent)
    temporary = Path(name)
    cleanup = True
    descriptor_open = True
    try:
        fcntl.flock(original, fcntl.LOCK_EX | fcntl.LOCK_NB)
        verify_identity(path, expected)
        original_info = os.fstat(original)
        require(path.stat().st_ino == original_info.st_ino, "Reference replaced before lock")
        with os.fdopen(descriptor, "wb") as stream:
            descriptor_open = False
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(mode)
        replacement = {"sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)}
        replacement_inode = temporary.stat().st_ino
        exchange(temporary, path)
        cleanup = False
        try:
            require(temporary.lstat().st_ino == original_info.st_ino,
                    "Concurrent reference replacement detected")
            verify_identity(temporary, expected)
            verify_identity(path, replacement)
        except (OSError, ValueError):
            # Preserve the displaced write. Restore it only while both
            # endpoints still have the identities just observed.
            displaced = stamp(temporary)
            require(path.lstat().st_ino == replacement_inode, "Reference conflict requires reconciliation")
            verify_identity(path, replacement)
            require(stamp(temporary) == displaced, "Displaced reference changed")
            exchange(temporary, path)
            verify_identity(temporary, replacement)
            cleanup = True
            raise
        cleanup = True
    finally:
        if descriptor_open:
            os.close(descriptor)
        os.close(original)
        if cleanup and temporary.exists():
            temporary.unlink()


def check_evidence(stage, record, key):
    identity = record[key + "Identity"]
    _, data = owned_bytes(stage / record[key], identity["sha256"], identity["bytes"],
                          bounded=8 * 1024 * 1024)
    return data


def verify_identity(path, identity):
    return owned_bytes(path, identity["sha256"], identity["bytes"])


def verify_root(path, plan):
    require(path.resolve(strict=True) == path and path.is_dir() and not path.is_symlink(),
            "Root ancestry or directory type changed")
    observed = stamp(path)
    require(all(observed[key] == plan["rootStamp"][key] for key in ("device", "inode", "mode")),
            "Moved root ownership changed")


def apply(stage, quiescent):
    stage = Path(stage)
    plan = json.loads((stage / "migration.json").read_text())
    require(plan["state"] == "prepared", "Migration is not untouched prepared state")
    old, new = Path(plan["old"]), Path(plan["new"])
    require(quiescent(), "Managed processes are not quiescent")
    require(stamp(old) == plan["rootStamp"] and not new.exists() and not new.is_symlink(),
            "Root changed or destination collision")
    require(stamp(old / plan["partial"]) == plan["partialStamp"], "Partial changed")
    require({path.name: stamp(path) for path in old.iterdir()} == plan["children"], "Root children changed")
    require(not (Path(plan["files"][0]["path"]).parent / "game-operation.json").exists(),
            "Active operation journal must be reconciled")
    for record in plan["files"]:
        verify_identity(Path(record["path"]), record["beforeIdentity"])
        check_evidence(stage, record, "before")
        check_evidence(stage, record, "after")
    changed = []
    moved = False
    try:
        require(quiescent(), "Managed processes resumed before move")
        verify_root(old, plan)
        require(not new.exists() and not new.is_symlink()
                and new.parent.resolve(strict=True) == new.parent, "Destination ancestry changed")
        # macOS exclusive rename refuses even an empty destination created
        # between the collision check and this operation.
        exclusive_rename(old, new)
        moved = True
        verify_root(new, plan)
        plan["state"] = "root_moved"
        save(stage, plan)
        for record in plan["files"]:
            path = Path(record["path"])
            verify_identity(path, record["beforeIdentity"])
            verify_root(new, plan)
            atomic_write(path, check_evidence(stage, record, "after"), record["stamp"]["mode"],
                         record["beforeIdentity"])
            changed.append(record)
        require(stamp(new / plan["partial"]) == plan["partialStamp"], "Partial identity changed")
        require({path.name: stamp(path) for path in new.iterdir()} == plan["children"],
                "Root children identity changed")
        for record in plan["files"]:
            verify_identity(Path(record["path"]), record["afterIdentity"])
        plan["state"] = "migrated_quiescent"
        save(stage, plan)
    except (OSError, ValueError) as error:
        plan["error"] = str(error)
        try:
            if moved:
                verify_root(new, plan)
            else:
                verify_root(old, plan)
            for record in reversed(changed):
                path = Path(record["path"])
                verify_identity(path, record["afterIdentity"])
                atomic_write(path, check_evidence(stage, record, "before"), record["stamp"]["mode"],
                             record["afterIdentity"])
            if moved:
                require(not old.exists() and not old.is_symlink(), "Rollback source collision")
                verify_root(new, plan)
                exclusive_rename(new, old)
                verify_root(old, plan)
            require(stamp(old / plan["partial"]) == plan["partialStamp"],
                    "Rollback partial identity differs")
            require({path.name: stamp(path) for path in old.iterdir()} == plan["children"],
                    "Rollback root children differ")
            for record in plan["files"]:
                verify_identity(Path(record["path"]), record["beforeIdentity"])
            plan["state"] = "rolled_back_quiescent"
        except (OSError, ValueError) as rollback_error:
            plan["state"] = "rollback_requires_reconciliation"
            plan["rollbackError"] = str(rollback_error)
        save(stage, plan)
        raise
    return plan


def exclusive_rename(source, destination):
    rename_flags(source, destination, 4)


def exchange(source, destination):
    rename_flags(source, destination, 2)


def rename_flags(source, destination, flags):
    import ctypes
    import sys
    require(sys.platform == "darwin", "Live migration requires macOS exclusive rename")
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    function = libc.renamex_np
    function.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    if function(os.fsencode(source), os.fsencode(destination), flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
