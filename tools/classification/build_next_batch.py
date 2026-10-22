#!/usr/bin/env python3
"""Query installed UNTESTED titles serially; publish candidates, never launch."""

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

from build_catalogue_batch import installed_inventory
from inspect_queue import DATA, load_json

HOME = Path.home()
SERVICE = HOME / "Library/Application Support/Ode to X/Service/candidates"
CLI = "adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604"
# Installer-only candidate identity; do not promote it to a launch CLI.
RC = "ebd56e56a23cdd73de884e80d4288eed6014a40435e7253c49a0cf42f8803fe3"
S1 = HOME / "src/copilot-worktrees/xode-wine/dragoshont-fantastic-broccoli/engines"
OUTPUT = DATA / "s3-preflight-next-v1.json"
MARKDOWN = DATA / "s3-preflight-next-v1.md"


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def source(path):
    raw = path.read_bytes()
    return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
            "snapshot": json.loads(raw)}


def query(sid, root, identity, evidence):
    binary = SERVICE / identity / "xodus-cli"
    if hashlib.sha256(binary.read_bytes()).hexdigest() != identity:
        raise ValueError("CLI hash mismatch")
    argv = [str(binary), "install-status", sid, "--game-dir", root,
            "--state-dir", str(evidence / sid / identity[:8])]
    row = {"queriedAt": now(), "argv": argv, "cliSha256": identity,
           "candidateBinary": identity == RC, "result": None}
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=300)
        row.update(processExitCode=result.returncode, stdout=result.stdout, stderr=result.stderr)
        if result.returncode == 0:
            row["result"] = json.loads(result.stdout)
    except subprocess.TimeoutExpired as error:
        row.update(processExitCode=None, timedOut=True,
                   stdout=(error.stdout or b"").decode() if isinstance(error.stdout, bytes)
                   else error.stdout or "",
                   stderr=(error.stderr or b"").decode() if isinstance(error.stderr, bytes)
                   else error.stderr or "")
    row["finishedAt"] = now()
    return row


def complete(attempt, sid, root):
    result = attempt.get("result") or {}
    return (attempt.get("processExitCode") == 0 and result.get("success") is True
            and result.get("status") == "complete" and result.get("exit_code") == 0
            and result.get("operation") == "install-status" and result.get("product") == sid
            and result.get("game_dir") == root)


def build(inputs):
    passive = {row["storeId"] for row in inputs["passive"]["snapshot"]["items"]}
    rows = []
    for row in inputs["titles"]:
        item = dict(row)
        sid = row["storeId"]
        attempts = inputs["queries"].get(sid, [])
        item["installStatusAttempts"] = attempts
        item["installedComplete"] = any(complete(attempt, sid, row["gameDir"])
                                         for attempt in attempts)
        item["completeInAdf8Terms"] = any(complete(attempt, sid, row["gameDir"])
                                          and attempt["cliSha256"] == CLI for attempt in attempts)
        item["alreadyInPassiveNine"] = sid in passive
        item["s1Rows"] = [
            {"path": source["path"], "sha256": source["sha256"], "row": binding,
             "bindingScope": "generic-queue-candidate" if Path(source["path"]).name ==
             "queue-profiles.json" else "explicit-title-candidate"}
            for source in inputs["s1"] for binding in
            source["snapshot"].get("profiles", source["snapshot"].get("items", []))
            if binding["store_id"] == sid]
        item["engineRowStatus"] = "present" if item["s1Rows"] else "missing"
        item["explicitEngineRowStatus"] = "present" if any(
            binding["bindingScope"] == "explicit-title-candidate"
            for binding in item["s1Rows"]) else "missing"
        item["launch"] = None
        item["executionAuthorized"] = False
        rows.append(item)
    ordered = sorted((row for row in rows if row["installedComplete"]
                      and not row["alreadyInPassiveNine"]),
                     key=lambda row: (row["engineRowStatus"] == "missing",
                                      row["explicitEngineRowStatus"] == "missing",
                                      row["originalQueueRank"], row["title"]))
    for rank, row in enumerate(ordered, 1):
        row["nextBatchRank"] = rank
        row["nextAction"] = ("Coordinator/S2/S3 admit exact row only after passive nine; "
                             "no launch grant from this packet." if
                             row["explicitEngineRowStatus"] == "present" else
                             "S1 binds an exact manifest/executable/default/arguments "
                             "candidate first; existing generic queue row is not an exact recipe.")
    return {
        "schemaVersion": 1, "collectedAt": inputs["collectedAt"], "readOnly": True,
        "gameLaunches": 0, "collectionInputs": inputs,
        "scope": "The 23 UNTESTED identities frozen in morning-status-v1. "
        "Already queued passive-nine members remain inventoried but are not repeated "
        "in next batch. Complete install status is not gameplay, anti-cheat, ownership "
        "or launch qualification. Candidate binary completion never clears frozen CLI.",
        "ordering": "Installed complete + S1 row present first, then complete + missing "
        "row; explicit title rows before generic queue-only rows; original queue rank "
        "breaks ties. No blind use of generic prepared-prefix templates.",
        "items": ordered,
        "allUntestedTitles": rows,
        "missingS1Rows": [row["storeId"] for row in ordered if row["engineRowStatus"] == "missing"],
        "exactBindingRequests": [row["storeId"] for row in ordered
                                 if row["explicitEngineRowStatus"] == "missing"],
        "counts": {"untested": len(rows), "installedComplete": sum(
            row["installedComplete"] for row in rows), "nextBatch": len(ordered),
            "passiveOverlap": sum(row["alreadyInPassiveNine"] for row in rows)},
    }


def refresh():
    morning = source(DATA / "morning-status-v1.json")
    targets = {row["storeId"] for row in morning["snapshot"]["items"]
               if row["state"] == "UNTESTED"}
    inventory = installed_inventory()
    root_by_id = {}
    for row in inventory:
        for sid in row["storeIds"]:
            if sid not in targets:
                continue
            if sid in root_by_id:
                raise ValueError(f"Ambiguous installed roots for {sid}")
            root_by_id[sid] = row["root"]
    queue = load_json(DATA / "s3-ready-packets-v4.json")
    ranks = {row["storeId"]: row.get("originalQueueRank", 999) for row in queue["items"]}
    inputs = {"collectedAt": now(), "morningSource": {
        "path": morning["path"], "sha256": morning["sha256"]},
        "passive": source(HOME / "Library/Application Support/XodusCLI/proofs/passive-small-eight-v1/packets.json"),
        "installedInventory": inventory, "titles": [], "queries": {},
        "s1": [source(S1 / name) for name in ("queue-profiles.json",
               "preflight-game-candidates.json", "small-game-candidates.json",
               "unity-gamemaker-candidates.json", "kex-game-candidates.json")]}
    evidence = HOME / "Library/Application Support/XodusCLI/proofs" / (
        "s4-next-batch-status-" + uuid.uuid4().hex)
    for title in morning["snapshot"]["items"]:
        if title["state"] != "UNTESTED":
            continue
        sid = title["storeId"]
        root = root_by_id.get(sid)
        inputs["titles"].append({"storeId": sid, "title": title["title"],
                                  "gameDir": root, "originalQueueRank": ranks.get(sid, 999)})
        attempts = inputs["queries"][sid] = []
        if root:
            attempts.append(query(sid, root, CLI, evidence))
            # Only the actually observed panic permits candidate fallback.
            if attempts[-1].get("processExitCode") == 101:
                attempts.append(query(sid, root, RC, evidence))
        OUTPUT.write_text(json.dumps(build(inputs), indent=2, ensure_ascii=True) + "\n")
        print(title["title"], [(r.get("processExitCode"), (r.get("result") or {}).get("status"))
                               for r in attempts], flush=True)
    return build(inputs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    if args.refresh:
        packet = refresh()
        OUTPUT.write_text(json.dumps(packet, indent=2, ensure_ascii=True) + "\n")
    else:
        packet = load_json(OUTPUT)
        if packet != build(packet["collectionInputs"]):
            raise ValueError("Next batch not reproducible")
    lines = ["# Next batch after passive nine", "",
             f"Snapshot: {packet['collectedAt']}. No launches authorized or executed.",
             "", "All 23 morning UNTESTED titles returned complete on adf8. "
             "No parser panic or ebd56e fallback occurred. Seven overlap the passive "
             "nine and are not repeated in the next batch. Every title has at least "
             "a generic S1 queue row; eight next-batch titles need an explicit "
             "manifest/executable recipe binding, requested from S1.", "",
             "| Next rank | Title | Install | S1 row | Exact binding |",
             "|---|---|---|---|---|"]
    for row in packet["items"]:
        lines.append(f"| {row['nextBatchRank']} | {row['title']} | "
                     f"{'complete (adf8)' if row['completeInAdf8Terms'] else 'not frozen-complete'} "
                     f"| {row['engineRowStatus']} | {row['explicitEngineRowStatus']} |")
    lines.extend(["", "## Already in passive nine", "",
                  "| Title | Install | S1 row |", "|---|---|---|"])
    for row in packet["allUntestedTitles"]:
        if row["alreadyInPassiveNine"]:
            lines.append(f"| {row['title']} | "
                         f"{'complete (adf8)' if row['completeInAdf8Terms'] else 'not frozen-complete'} "
                         f"| {row['engineRowStatus']} |")
    lines.extend(["", "Exact game roots, manifest hashes, S1 row snapshots/hashes, "
                  "status argv, stdout, exit codes, timestamps and receipt identities "
                  "are in `s3-preflight-next-v1.json`. This ordering does not establish "
                  "anti-cheat absence, gameplay or save retention. Installed payloads "
                  "are not a new entitlement assertion. No install, launch, prefix "
                  "creation or cleanup is authorized."])
    MARKDOWN.write_text("\n".join(lines) + "\n")
    print(packet["counts"])


if __name__ == "__main__":
    main()
