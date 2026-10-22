#!/usr/bin/env python3
"""Read-only allocated-space audit. Never deletes or reads game/save contents."""

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

from inspect_queue import DATA, load_json

HOME = Path.home()
WORKTREES = HOME / "src/copilot-worktrees"
SUPPORT = HOME / "Library/Application Support"
CLI = SUPPORT / "XodusCLI"
MATRIX = HOME / ".copilot/session-state/24963110-1b48-4e35-bae1-a54927543f42/files/s3-tried-games.json"
OUTPUT = DATA / "reclaimable-space-v1.json"
OWNERS = {
    str(WORKTREES / "xodus-macos/dragoshont-fluffy-guide"): "S2",
    str(WORKTREES / "xodus-macos-app/dragoshont-super-spork"): "S5 (active build hold)",
    str(WORKTREES / "xodus-macos-app/dragoshont-verbose-dollop"): "S4",
    str(WORKTREES / "xode-wine/dragoshont-fantastic-broccoli"): "S1",
}


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def measure(path):
    result = subprocess.run(["/usr/bin/du", "-sk", str(path)],
                            capture_output=True, text=True, check=False)
    line = result.stdout.splitlines()
    return {
        "allocatedBytes": int(line[-1].split()[0]) * 1024 if line else None,
        "measurementComplete": result.returncode == 0,
        "measurementError": result.stderr.strip() or None,
    }


def build_dirs():
    for root, dirs, _ in os.walk(WORKTREES):
        path = Path(root)
        if len(path.relative_to(WORKTREES).parts) > 5:
            dirs[:] = []
            continue
        dirs[:] = [name for name in dirs if name not in {".git", "node_modules"}]
        if path.name in {".build", "target", "DerivedData"}:
            dirs[:] = []
            yield path


def main():
    now = dt.datetime.now(dt.timezone.utc)
    matrix = load_json(MATRIX)
    ids = set(matrix["workingAdmission"]["qualifiedProductIds"])
    working = [row for row in matrix["games"] if row["productId"] in ids]
    working_strings = list(strings(working))
    sources = {str(MATRIX): "\n".join(working_strings)}
    warnings = []
    pending = [Path(text) for text in working_strings
               if text.startswith("/") and text.endswith(".json")]
    for path in pending:
        if str(path) in sources or not path.is_file():
            continue
        if "/Games/" in str(path) or "save" in path.name.lower() and "snapshot" not in path.name:
            continue
        try:
            value = load_json(path)
        except (json.JSONDecodeError, OSError) as error:
            warnings.append({"path": str(path), "error": str(error)})
            continue
        text = "\n".join(strings(value))
        sources[str(path)] = text
        for link in strings(value):
            if link.startswith("/") and link.endswith(".json") and len(pending) < 200:
                pending.append(Path(link))
    for root in (CLI / "runs", CLI / "proofs", DATA):
        for path in root.rglob("*.json"):
            if path == OUTPUT or path.is_symlink() or path.stat().st_size > 8 * 2**20:
                continue
            try:
                value = load_json(path)
            except (json.JSONDecodeError, OSError) as error:
                warnings.append({"path": str(path), "error": str(error)})
                continue
            sources[str(path)] = "\n".join(strings(value))
    for name in ("registry.json", "queue-profiles.json", "small-game-candidates.json"):
        path = WORKTREES / "xode-wine/dragoshont-fantastic-broccoli/engines" / name
        if path.exists():
            sources[str(path)] = "\n".join(strings(load_json(path)))

    rows = []

    def add(path, category, disposition, owner=None, **extra):
        if not path.exists() or path.is_symlink():
            return
        owner = owner or next((value for root, value in OWNERS.items()
                               if str(path).startswith(root + "/")),
                              "Host user / other worktree owner; no deletion window obtained")
        refs = [source for source, text in sources.items()
                if source != str(path) and str(path) in text]
        rows.append({
            "path": str(path), "category": category, "owner": owner,
            **measure(path), "receiptReferences": refs,
            "referencesAreExhaustive": False,
            "disposition": disposition, **extra,
        })

    for path in sorted(build_dirs()):
        add(path, "build-root",
            "AUDIT ONLY: may contain referenced executables/release artifacts; never delete whole root.")
        for relative in ("debug/incremental", "out/Intermediates.noindex",
                         "out/ModuleCache.noindex", "out/SDKExplicitPrecompiledModules"):
            leaf = path / relative
            add(leaf, "compiler-intermediates",
                "Pre-approved class, but requires unreferenced/quiescent exact-path confirmation; "
                "S5 compiler directories currently HELD.")
        if path.name == ".build":
            for app in path.glob("local-candidates/**/*.app"):
                info = app / "Contents/Info.plist"
                metadata = {}
                if info.is_file():
                    with info.open("rb") as stream:
                        plist = plistlib.load(stream)
                    metadata = {key: value for key, value in plist.items()
                                if any(word in key.lower() for word in ("commit", "version", "revision"))}
                add(app, "candidate-app", "Approval required; keep c22029c,8140bb2,"
                    "c1190cc backup and every referenced release artifact.", metadata=metadata)
            for dmg in path.glob("local-candidates/**/*.dmg"):
                add(dmg, "candidate-dmg", "Approval required; not compiler intermediates.")
    add(HOME / "Library/Developer/Xcode/DerivedData", "derived-data",
        "Pre-approved class only after referenced Products and active builds excluded.")
    add(HOME / "Library/Caches", "user-cache-total",
        "AUDIT ONLY: overlaps children; protected macOS cache sizes may be incomplete.")
    for path in sorted((HOME / "Library/Caches").iterdir()):
        add(path, "user-cache", "Approval required; not assumed to be completed-install cache.")
    for path in sorted((CLI / "prefixes").iterdir()):
        add(path, "cli-prefix", "HOLD: no prefix/save deletion, including probe prefixes.",
            "S2/S3", olderThanTwoHours=now.timestamp() - path.stat().st_mtime > 7200)
    for path in sorted((CLI / "runs").iterdir()):
        if not path.is_dir():
            continue
        result = path / "result.json"
        old = now.timestamp() - path.stat().st_mtime > 7200
        if result.exists():
            try:
                receipt = load_json(result)
                finished = receipt.get("finished_at")
                if finished:
                    old = (now - dt.datetime.fromisoformat(finished.replace("Z", "+00:00"))).total_seconds() > 7200
            except (json.JSONDecodeError, ValueError) as error:
                warnings.append({"path": str(result), "error": str(error)})
        if old:
            add(path, "old-cli-run", "Approval required; preserve all evidence/receipt references.",
                "S2/S3", olderThanTwoHours=True)
    add(CLI / "proofs", "proof-evidence", "HOLD: evidence, not cache.", "S2/S3")
    add(SUPPORT / "Ode to X/Engines/downloads", "engine-downloads",
        "Approval required: engine archives/logs, not proven completed game-install caches.", "S1")
    for root in (CLI, HOME / "Library/Caches/Xodus",
                 SUPPORT / "Ode to X/Service"):
        for path in root.iterdir():
            if any(word in path.name.lower() for word in ("download", "cache", "temp", "partial")):
                add(path, "possible-installer-cache",
                    "HOLD until exact completed-install ownership verified; never payload partials.")
    stat = os.statvfs(HOME / "Games/Xodus")
    packet = {
        "schemaVersion": 1, "collectedAt": now.isoformat(), "readOnly": True,
        "freeBytes": stat.f_bavail * stat.f_frsize, "deletedPaths": [],
        "workingProductIds": sorted(ids),
        "matrix": {"path": str(MATRIX), "sha256": hashlib.sha256(MATRIX.read_bytes()).hexdigest()},
        "referenceScanScope": "Available CLI/proof/S4 JSON metadata <=8MiB, S1 profile JSON "
        "and linked WORKING JSON receipts. Not a proof of absence across arbitrary logs. "
        "Prefixes, runs, release artifacts and general caches remain held regardless.",
        "referenceSources": sorted(sources), "warnings": warnings, "items": rows,
        "overlapWarning": "Parent roots and children overlap; do not sum row sizes.",
        "protected": ["All game payloads and saves", "All WORKING prefixes/receipts",
                      "All release artifacts until explicit approval", "S5 .build active hold",
                      "Brotato partial root and run8c15"],
    }
    OUTPUT.write_text(json.dumps(packet, indent=2, ensure_ascii=True) + "\n")
    print(len(rows), "measured rows; no deletions; freeGiB", round(packet["freeBytes"] / 2**30, 2))


if __name__ == "__main__":
    main()
