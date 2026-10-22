#!/usr/bin/env python3
"""Snapshot candidate save metadata and streaming hashes; never launch or parse saves."""

import argparse
import collections
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat

from inspect_queue import DATA, load_json

HOME = Path.home()
CLI = HOME / "Library/Application Support/XodusCLI"
SPEC = HOME / "src/copilot-worktrees/xode-wine/dragoshont-fantastic-broccoli/engines/retention-checks.md"
PLAN = CLI / "proofs/passive-small-eight-v1/packets.json"
OUTPUT = DATA / "save-baseline-v1.json"
TITLE_TOKENS = {
    "9MT5NJ5W7B8Z": ("hogwarts", "phx"),
    "9PCR3Z2MSM4T": ("hades", "supergiant"),
    "9P4NV23Q6QC2": ("abiotic",),
    "9P9VNSQK1W3K": ("brotato",),
    "9P8NSTDMZ11P": ("inscryption",),
    "9MSVVM5NS9L6": ("dredge", "black salt"),
    "9PBWWQGXVMKC": ("monster sanctuary", "monstersanctuary"),
    "9NLRT31Z4RWM": ("tunic", "andrew shouldice", "secret legend"),
    "9PD5BM2Z8C4L": ("vampire", "poncle"),
    "9NGH1FK0RJGL": ("wasteland", "inxile"),
    "9NV3L234VGXD": ("replaced", "sad cat"),
    "9PLH7R84GJWP": ("well dweller", "welldweller"),
}
# These are discovery candidates, not claims about effective Xbox storage.
CANDIDATES = {
    "9MT5NJ5W7B8Z": ["L/Packages/WarnerBros.Interactive.PHX_ktmk1xygcecda/SystemAppData/wgs",
                      "L/Hogwarts Legacy/Saved/SaveGames"],
    "9PCR3Z2MSM4T": ["S/Hades II", "D/Saved Games/Hades II", "D/Hades II"],
    "9P4NV23Q6QC2": ["L/AbioticFactor/Saved/SaveGames", "D/AbioticFactor"],
    "9P9VNSQK1W3K": ["R/Brotato"],
    "9P8NSTDMZ11P": ["L/Packages/DevolverDigital.Inscryption_6kzv4j18v0c96/SystemAppData/wgs"],
    "9MSVVM5NS9L6": ["LL/Black Salt Games/DREDGE/saves"],
    "9PBWWQGXVMKC": ["D/My Games/Monster Sanctuary"],
    "9NLRT31Z4RWM": ["L/Packages/Finji.TUNIC_tys0ffscxatjj/SystemAppData/wgs",
                      "LL/Andrew Shouldice/Secret Legend/SAVES"],
    "9PD5BM2Z8C4L": ["L/Packages/poncle.VampireSurvivors_9pv5cyp4vwdsr/SystemAppData/wgs",
                      "R/Vampire_Survivors/saves"],
    "9NGH1FK0RJGL": ["D/My Games/Wasteland Remastered"],
    "9NV3L234VGXD": ["L/Packages/Thunderful.REPLACED-Game_8j53pwgd019sy/SystemAppData/wgs"],
    "9PLH7R84GJWP": ["R/WellDweller"],
}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fingerprint(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def hash_file(path):
    """Reject links and unstable reads rather than admitting a misleading hash."""
    before = path.lstat()
    row = {"path": str(path), "sizeBytes": before.st_size,
           "mtimeNs": before.st_mtime_ns, "sha256": None,
           "nameOnlyRole": "deletion-marker" if ".deleted" in path.name else
           "configuration-name" if path.suffix.lower() in {".cfg", ".ini"} else
           "unclassified-candidate",
           "gameplayPayloadEstablished": False}
    if not stat.S_ISREG(before.st_mode):
        return {**row, "status": "not-regular"}
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if fingerprint(before) != fingerprint(opened):
            return {**row, "status": "changed-before-hash"}
        value = hashlib.file_digest(stream, "sha256").hexdigest()
        after = os.fstat(stream.fileno())
    current = path.lstat()
    if fingerprint(before) != fingerprint(after) or fingerprint(after) != fingerprint(current):
        return {**row, "status": "changed-during-hash"}
    return {**row, "status": "stable-during-read", "sha256": value}


def inventory(path, allowed):
    row = {"path": str(path), "files": [], "symlinks": [], "errors": [],
           "absentMeans": "Candidate path absent at observation, not proof of no save."}
    try:
        resolved = path.resolve()
        row["resolvedRoot"] = str(resolved)
        if not any(resolved == base.resolve() or base.resolve() in resolved.parents
                   for base in allowed):
            return {**row, "status": "out-of-scope-target"}
        if path.is_symlink():
            row["symlinks"].append({"path": str(path), "target": os.readlink(path)})
        if not path.exists():
            return {**row, "status": "absent"}
        if path.is_file():
            row["files"].append(hash_file(resolved))
        else:
            def walk_error(error):
                row["errors"].append({"path": str(error.filename), "error": str(error)})

            for root, dirs, files in os.walk(resolved, followlinks=False, onerror=walk_error):
                for name in list(dirs) + files:
                    entry = Path(root, name)
                    if entry.is_symlink():
                        row["symlinks"].append({"path": str(entry), "target": os.readlink(entry),
                                                "followed": False})
                        if name in dirs:
                            dirs.remove(name)
                        continue
                    if name in files:
                        try:
                            row["files"].append(hash_file(entry))
                        except OSError as error:
                            row["errors"].append({"path": str(entry), "error": str(error)})
        row["status"] = "unreadable-or-incomplete" if row["errors"] else (
            "present" if row["files"] or row["symlinks"] else "empty")
    except (OSError, RuntimeError) as error:
        row.update(status="unreadable-or-incomplete")
        row["errors"].append({"path": str(path), "error": str(error)})
    row["files"].sort(key=lambda item: item["path"])
    row["fileSetSha256"] = hashlib.sha256(json.dumps(
        [(item["path"], item["sizeBytes"], item["sha256"], item["status"])
         for item in row["files"]], sort_keys=True).encode()).hexdigest()
    return row


def discover(base, tokens, depth=2):
    """Only inspect bounded directory names; never traverse links or unrelated subtrees."""
    if not base.is_dir():
        return []
    found = []
    for child in sorted(base.iterdir()):
        if any(token in child.name.lower() for token in tokens):
            found.append(child)
        elif depth > 1 and child.is_dir() and not child.is_symlink():
            found.extend(discover(child, tokens, depth - 1))
    return found


def collect():
    if digest(SPEC) != "6b4404849fd5c8afffab6ed58a0f87ee435d03182e113c025a9d1c32fd98be87":
        raise ValueError("Checklist differs from requested dbfae0b")
    plan = load_json(PLAN)
    passive = plan["items"]
    if len(passive) != 9 or {row["storeId"] for row in passive} != set(TITLE_TOKENS) - {
            "9MT5NJ5W7B8Z", "9PCR3Z2MSM4T", "9P4NV23Q6QC2"}:
        raise ValueError("Passive-nine identity differs; rebind scope before collecting")
    titles = {row["storeId"]: row["title"] for row in passive}
    titles.update({"9MT5NJ5W7B8Z": "Hogwarts Legacy", "9PCR3Z2MSM4T": "Hades II",
                   "9P4NV23Q6QC2": "Abiotic Factor"})
    results = collections.defaultdict(list)
    paths = list((CLI / "runs").glob("*/result.json"))
    paths += list((CLI / "proofs").glob("*/runs/*/result.json"))
    for path in sorted(paths):
        raw = path.read_bytes()
        result = json.loads(raw)
        sid = result.get("product")
        if sid not in titles or result.get("operation") != "launch" or not result.get("prefix"):
            continue
        results[sid].append({"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
                             **{key: result.get(key) for key in
                                ("prefix", "started_at", "run_id", "game_dir", "launch_receipt_path")}})
    packet = {"schemaVersion": 1, "startedAt": now(), "readOnly": True, "gameLaunches": 0,
              "saveContentsParsed": False, "retentionPass": False,
              "spec": {"path": str(SPEC), "commit": "dbfae0b", "sha256": digest(SPEC)},
              "passivePlan": {"path": str(PLAN), "sha256": digest(PLAN)},
              "policy": "Observation baseline only, not retroactive pre-launch T0. "
              "All hashes provisional with respect to process quiescence; no processes "
              "stopped or absence certified. Stable-during-read only rejects observed "
              "read races, not later changes. Missing/unmapped roots never prove no save. "
              "No save contents decoded. Candidate settings/backups/deletion markers "
              "are inventoried without treating them as gameplay. Full account paths local only.",
              "items": []}
    for sid, title in titles.items():
        item = {"storeId": sid, "title": title, "prefixes": [], "roots": [],
                "candidateRouteStatus": "Discovery only; effective payload route unverified",
                "candidateTemplates": ["L/XodusPrivateContainerSaves", *CANDIDATES[sid]],
                "templatePolicy": "Templates remain unbound where a prefix or effective "
                "user directory is absent; not an absent effective payload claim."}
        receipts = sorted(results[sid], key=lambda row: row.get("started_at") or "")
        bindings = {}
        for receipt in receipts:
            bindings[receipt["prefix"]] = {"path": receipt["prefix"],
                                          "binding": "existing-launch-receipt", "receipt": receipt}
        planned = next((row for row in passive if row["storeId"] == sid), None)
        if planned and planned["prefix"] not in bindings:
            bindings[planned["prefix"]] = {"path": planned["prefix"],
                                           "binding": "planned-only-not-an-admitted-launch"}
        if sid == "9PLH7R84GJWP":
            observed = CLI / "prefixes/s3-well-d3dmetal-v1"
            if observed.is_dir() and str(observed) not in bindings:
                bindings[str(observed)] = {
                    "path": str(observed),
                    "binding": "existing-title-named-directory-launch-receipt-unmapped",
                    "warning": "Do not treat directory name as an admitted actual run."}
        item["prefixes"] = list(bindings.values())
        candidates = {}
        for binding in item["prefixes"]:
            prefix = Path(binding["path"])
            binding["exists"] = prefix.is_dir()
            binding["status"] = "present" if prefix.is_dir() else "absent"
            if not prefix.is_dir():
                continue
            users = prefix / "drive_c/users"
            user = users / "crossover"
            if not user.is_dir() or user.is_symlink():
                binding["effectiveUserStatus"] = "unmapped; no unrelated user directories traversed"
                continue
            for user in [user]:
                locations = {"L": user / "AppData/Local", "LL": user / "AppData/LocalLow",
                             "R": user / "AppData/Roaming", "D": user / "Documents",
                             "S": user / "Saved Games"}
                candidate = locations["L"] / "XodusPrivateContainerSaves"
                candidates[str(candidate)] = (candidate, [prefix.resolve(), HOME / "Documents"])
                for rel in CANDIDATES[sid]:
                    symbol, rest = rel.split("/", 1)
                    candidate = locations[symbol] / rest
                    candidates[str(candidate)] = (candidate, [prefix.resolve(), HOME / "Documents"])
                for symbol, base in locations.items():
                    if symbol == "D":
                        binding["documents"] = {"path": str(base), "resolved": str(base.resolve()),
                                                "symlink": os.readlink(base) if base.is_symlink() else None}
                    for candidate in discover(base, TITLE_TOKENS[sid]):
                        # Package directories: hash only native WGS, not game installs/cache.
                        if candidate.parent.name == "Packages":
                            candidate = candidate / "SystemAppData/wgs"
                        elif symbol == "L" and sid in {"9P4NV23Q6QC2", "9MT5NJ5W7B8Z"}:
                            candidate = candidate / "Saved/SaveGames"
                        candidates[str(candidate)] = (candidate, [prefix.resolve(), HOME / "Documents"])
                stage = binding.get("receipt", {}).get("launch_receipt_path")
                if sid == "9P8NSTDMZ11P" and stage and Path(stage).is_file():
                    launch = load_json(Path(stage))
                    for cwd in [Path(binding["receipt"]["game_dir"]),
                                Path(launch["staged_executable"]).parent]:
                        for name in ("SaveFile.gwsave", "SaveFile-Backup.gwsave"):
                            candidate = cwd / name
                            candidates[str(candidate)] = (candidate, [cwd.resolve()])
        if sid == "9P8NSTDMZ11P":
            game = Path(planned["gameDir"])
            names = {"SaveFile.gwsave", "SaveFile-Backup.gwsave"}
            names.update(path.name for path in game.glob("SaveFile*gwsave*"))
            for name in sorted(names):
                candidate = game / name
                candidates[str(candidate)] = (candidate, [game.resolve()])
        # Documents is shared; inspect title-specific names only, even with no prefix.
        documents = HOME / "Documents"
        for rel in CANDIDATES[sid]:
            if rel.startswith("D/"):
                path = documents / rel[2:]
                candidates[str(path)] = (path, [documents])
        for candidate in discover(documents, TITLE_TOKENS[sid]):
            candidates[str(candidate)] = (candidate, [documents])
        for candidate, allowed in candidates.values():
            item["roots"].append(inventory(candidate, allowed))
        item["snapshotStatus"] = "captured-existing-candidates" if any(
            root["files"] for root in item["roots"]) else "no-files-in-observed-candidates"
        item["unmappedWarning"] = "No effective payload namespace inferred for absent or unlaunched prefixes."
        packet["items"].append(item)
    packet["finishedAt"] = now()
    packet["summary"] = {
        "titleCount": len(packet["items"]),
        "fileObservations": sum(len(root["files"]) for item in packet["items"]
                                for root in item["roots"]),
        "rootStatusCounts": dict(collections.Counter(
            root["status"] for item in packet["items"] for root in item["roots"])),
        "fileStatusCounts": dict(collections.Counter(
            file["status"] for item in packet["items"]
            for root in item["roots"] for file in root["files"])),
    }
    return packet


def redact(packet):
    # Keep original paths solely in the local receipt. Every nested directory and
    # filename gets a deterministic alias, so account identifiers cannot leak.
    value = json.loads(json.dumps(packet))
    for item in value["items"]:
        for root in item["roots"]:
            resolved = root.get("resolvedRoot", root["path"])
            def safe(path):
                try:
                    parts = Path(path).relative_to(resolved).parts
                except ValueError:
                    return "<outside-root:" + hashlib.sha256(path.encode()).hexdigest()[:20] + ">"
                return str(Path(resolved, *[
                    "entry-" + hashlib.sha256(part.encode()).hexdigest()[:20] for part in parts]))
            for file in root["files"]:
                file["path"] = safe(file["path"])
            for link in root["symlinks"]:
                link["path"] = safe(link["path"])
                link["target"] = "<local-receipt-only>"
            for error in root["errors"]:
                error["path"] = safe(error["path"])
                error["error"] = "See full local receipt; not interpreted as absent."
    value["pathPrivacy"] = "Nested candidate paths use deterministic SHA-256 aliases; "
    value["pathPrivacy"] += "exact filenames/account paths remain solely in hash-bound local receipt."
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local-receipt", type=Path, required=True)
    args = parser.parse_args()
    if args.local_receipt.exists():
        raise ValueError("Refusing to overwrite historical baseline receipt")
    packet = collect()
    args.local_receipt.write_text(json.dumps(packet, indent=2, ensure_ascii=True) + "\n")
    public = redact(packet)
    public["localReceipt"] = {"path": str(args.local_receipt), "sha256": digest(args.local_receipt)}
    OUTPUT.write_text(json.dumps(public, indent=2, ensure_ascii=True) + "\n")
    print([(item["title"], sum(len(root["files"]) for root in item["roots"]))
           for item in packet["items"]])


if __name__ == "__main__":
    main()
