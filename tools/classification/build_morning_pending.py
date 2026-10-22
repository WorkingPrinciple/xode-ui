#!/usr/bin/env python3
"""Public Game Pass membership and metadata-only reclaim proposal; delete nothing."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import stat
import urllib.request

from build_catalogue_batch import installed_inventory
from inspect_queue import DATA, load_json

HOME = Path.home()
CATEGORY = "609d944c-d395-4c0a-9ea4-e9f39b52c1ad"
URL = ("https://catalog.gamepass.com/sigls/v3?id=" + CATEGORY +
       "&language=en-US&market=US&platformContext=pc&subscriptionContext=cfq7ttc0kgq8")
MATRIX = HOME / ".copilot/session-state/24963110-1b48-4e35-bae1-a54927543f42/files/s3-tried-games.json"
OUTPUT = DATA / "morning-pending-v1.json"
REASONS = {
    "9NGLST31DG26": ("conditional-user-review", "No validated startup fix: COM/factory "
                    "causality unknown. S1 has a cheap STA proposal, not a proven path; "
                    "retain if coordinator schedules that comparison."),
    "9PK087LNGJC5": ("conditional-user-review", "No observed render; cause unknown. "
                    "No qualified recipe or admitted rerun. API-trace research remains."),
    "9PLH7R84GJWP": ("retain-near-term", "Host repair evidence exists; passive-nine "
                    "actual-title retest is queued, so do not reclaim now."),
    "9P9VNSQK1W3K": ("retain-pending-decision", "Existing CLI RC fixes parser path; "
                    "user promotion decision pending, no launch qualification."),
    "C3KLDKZBHNCZ": ("retain-active-diagnostics", "Gameplay pass; save-provider "
                    "diagnostics pending, boundary defect not proven causal."),
    "9PCR3Z2MSM4T": ("retain-near-term", "Gameplay works; checkpoint/normal quit/reload gate."),
    "9MT5NJ5W7B8Z": ("retain-near-term", "Retained checkpoint proven; only normal quit gate remains."),
}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def source(path):
    raw = path.read_bytes()
    return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
            "snapshot": json.loads(raw)}


def measure(root):
    allocated = logical = count = 0
    seen = set()
    warnings = []
    def onerror(error):
        warnings.append({"path": str(error.filename), "error": str(error)})
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=onerror):
        dirs[:] = [name for name in dirs if not Path(directory, name).is_symlink()]
        for name in files:
            path = Path(directory, name)
            try:
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) in seen:
                    continue
                seen.add((info.st_dev, info.st_ino))
                allocated += info.st_blocks * 512
                logical += info.st_size
                count += 1
            except OSError as error:
                warnings.append({"path": str(path), "error": str(error)})
    return {"path": str(root), "allocatedBytes": allocated, "logicalBytes": logical,
            "regularFiles": count, "warnings": warnings, "contentsRead": False}


def build(inputs):
    feed = inputs["gamePass"]
    ids = set(feed.get("productIds", []))
    ranked = inputs["ranked"]["snapshot"]["blockedItems"]
    membership = [{
        "storeId": row["storeId"], "title": row["title"],
        "gamePassPcMembership": ("present" if row["storeId"] in ids else "absent")
        if feed["complete"] else "unknown",
        "source": {"url": URL, "checkedAt": feed["checkedAt"], "sha256": feed.get("sha256")},
        "ownership": "unknown", "installAuthorized": False,
    } for row in ranked]
    nominations = []
    dispositions = []
    for row in inputs["blockedPayloads"]:
        item = dict(row)
        category, reason = REASONS[row["storeId"]]
        item.update(disposition=category, reason=reason, deletionAuthorized=False)
        estimated = inputs["freeBytes"] + row["allocatedBytes"]
        item["estimatedFreeGiBAfterPayloadRemoval"] = estimated / 2**30
        item["diskFitOnlyCandidates"] = [
            {"storeId": candidate["storeId"], "title": candidate["title"],
             "downloadSizeBytes": candidate["downloadSizeBytes"]}
            for candidate in ranked if candidate["downloadSizeBytes"] <= estimated - 157 * 2**30]
        item["whatItWouldAllow"] = "Disk headroom only; still no ownership proof, "
        item["whatItWouldAllow"] += "batch approval or anti-cheat/offline clearance. Not a combined batch."
        dispositions.append(item)
        if category == "conditional-user-review":
            nominations.append(item)
    combined_free = inputs["freeBytes"] + sum(row["allocatedBytes"] for row in nominations)
    return {
        "schemaVersion": 1, "collectedAt": inputs["collectedAt"], "collectionInputs": inputs,
        "status": "PENDING user review; catalogue path closed tonight",
        "gamePassMembership": membership,
        "membershipPolicy": "Exact official PC feed and US/en-US scope behind app "
        "LiveSession catalog.discover/Game Pass filter. Public membership is not "
        "account entitlement, purchase ownership, offline or anti-cheat evidence.",
        "reclaimProposal": {
            "status": "PENDING; delete nothing", "deletedPaths": [],
            "freeBytesObserved": inputs["freeBytes"], "candidates": nominations,
            "combinedProposal": {
                "allocatedBytes": sum(row["allocatedBytes"] for row in nominations),
                "estimatedFreeGiB": combined_free / 2**30,
                "diskFitOnlyCandidates": [row["title"] for row in ranked
                                         if row["downloadSizeBytes"] <= combined_free - 157 * 2**30],
                "deletionAuthorized": False,
            },
            "allBlockedInstalledDispositions": dispositions,
            "policy": "Only payload-root removal is proposed for conditional user "
            "review, not approved. Prefixes, Documents/saves, licenses, evidence, "
            "app/engine archives and rollbacks stay held. Coordinator first confirms "
            "no near-term run and actual quiescence; use supported exact-target removal "
            "only after user decision. Allocation is not guaranteed APFS physical "
            "reclaim; clones/shared extents, other activity and re-download cost matter. "
            "Sizes are metadata-only, not freshness/completeness receipts.",
        }}


def refresh():
    feed = {"url": URL, "checkedAt": now(), "complete": False, "productIds": []}
    try:
        with urllib.request.urlopen(URL, timeout=30) as response:
            raw = response.read(512 * 1024 + 1)
            if response.status != 200 or len(raw) > 512 * 1024:
                raise ValueError("Invalid public feed status/size")
        values = json.loads(raw)
        if not isinstance(values, list) or not 2 <= len(values) <= 2049 \
                or values[0].get("siglId") != CATEGORY:
            raise ValueError("Invalid official PC feed identity")
        ids = [value["id"] for value in values[1:]]
        if len(set(ids)) != len(ids) or any(
                len(value) != 12 or not value.isascii() or not value.isalnum()
                or value.upper() != value for value in ids):
            raise ValueError("Invalid public product IDs")
        feed.update(complete=True, productIds=ids, sha256=hashlib.sha256(raw).hexdigest())
    except (OSError, ValueError, KeyError) as error:
        feed["error"] = str(error)
    morning = source(DATA / "morning-status-v1.json")
    blocked = {row["storeId"] for row in morning["snapshot"]["items"] if row["state"] == "BLOCKED"}
    inventory = installed_inventory()
    rows = []
    for root in inventory:
        for sid in root["storeIds"]:
            if sid not in blocked:
                continue
            if sid not in REASONS:
                raise ValueError(f"New blocked installed title requires disposition: {sid}")
            title = next(row["title"] for row in morning["snapshot"]["items"] if row["storeId"] == sid)
            rows.append({"storeId": sid, "title": title, **measure(Path(root["root"]))})
    volume = os.statvfs(HOME / "Games/Xodus")
    repo = Path(__file__).resolve().parents[2]
    backend = HOME / "src/copilot-worktrees/xodus-macos/dragoshont-fluffy-guide/crates/xodus-management/src/discovery.rs"
    ranked = source(DATA / "s3-preflight-catalogue-v1.json")
    ranked["snapshot"] = {"blockedItems": [
        {key: row[key] for key in ("storeId", "title", "downloadSizeBytes")}
        for row in ranked["snapshot"]["blockedItems"]]}
    inputs = {"collectedAt": now(), "gamePass": feed, "blockedPayloads": rows,
              "freeBytes": volume.f_bavail * volume.f_frsize,
              "ranked": ranked,
              "morningSource": {"path": morning["path"], "sha256": morning["sha256"]},
              "currentMatrix": source(MATRIX),
              "sourceCode": [{"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                             for path in [backend, repo / "Sources/XodusPreview/LiveSession.swift"]]}
    return build(inputs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--rebuild", action="store_true", help="Use frozen inputs, no HTTP or remeasurement")
    args = parser.parse_args()
    packet = refresh() if args.refresh else load_json(OUTPUT)
    if args.rebuild:
        packet = build(packet["collectionInputs"])
    if packet != build(packet["collectionInputs"]):
        raise ValueError("Pending proposal does not reproduce")
    if args.refresh or args.rebuild:
        OUTPUT.write_text(json.dumps(packet, indent=2, ensure_ascii=True) + "\n")
    lines = ["# Morning pending catalogue/reclaim decisions", "",
             f"Observed: {packet['collectedAt']}. **PENDING: no deletion or install authorized.**",
             "", "## Game Pass membership", "", packet["membershipPolicy"], "",
             "| Title | Official PC feed | Account ownership |",
             "|---|---|---|"]
    for row in packet["gamePassMembership"]:
        lines.append(f"| {row['title']} | {row['gamePassPcMembership']} | unknown |")
    proposal = packet["reclaimProposal"]
    lines.extend(["", "## Installed BLOCKED payload disposition", "",
                  f"Free: {proposal['freeBytesObserved'] / 2**30:.3f} GiB. "
                  "Sizes below are allocated file blocks, not guaranteed physical reclaim.", "",
                  "| Payload/title | Allocated GiB | Disposition | Ranked installs fitting after removal |",
                  "|---|---|---|---|"])
    for row in proposal["allBlockedInstalledDispositions"]:
        fit = ", ".join(item["title"] for item in row["diskFitOnlyCandidates"]) or "none"
        if row["disposition"] != "conditional-user-review":
            fit = "not proposed; retain"
        lines.append(f"| `{row['path']}` ({row['title']}) | "
                     f"{row['allocatedBytes'] / 2**30:.3f} | {row['disposition']}: "
                     f"{row['reason']} | {fit} |")
    combined = proposal["combinedProposal"]
    lines.extend(["", f"Conditional Digging + Balatro total: "
                  f"**{combined['allocatedBytes'] / 2**30:.3f} GiB**; estimated free "
                  f"**{combined['estimatedFreeGiB']:.3f} GiB**. Ranked-eight installs "
                  "fitting after BOTH removals: "
                  + (", ".join(combined["diskFitOnlyCandidates"]) or "**none**") + ". "
                  "No useful ranked-eight admission follows from these small removals.",
                  "", proposal["policy"], "", "Full source hashes, official feed URL/IDs, "
                  "metadata warnings and measured sizes: `morning-pending-v1.json`."])
    (DATA / "morning-pending-v1.md").write_text("\n".join(lines) + "\n")
    print([(row["title"], row["gamePassPcMembership"]) for row in packet["gamePassMembership"]])
    print("Free GiB", packet["reclaimProposal"]["freeBytesObserved"] / 2**30)
    print([(row["title"], row["allocatedBytes"] / 2**30)
           for row in packet["reclaimProposal"]["allBlockedInstalledDispositions"]])


if __name__ == "__main__":
    main()
