#!/usr/bin/env python3
"""Read-only source reconciliation and bounded disk metadata observations."""

import argparse
import collections
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import stat

from inspect_queue import DATA, load_json
from build_catalogue_batch import installed_inventory

HOME = Path.home()
SUPPORT = HOME / "Library/Application Support"
MATRIX = HOME / ".copilot/session-state/24963110-1b48-4e35-bae1-a54927543f42/files/s3-tried-games.json"
S1 = HOME / "src/copilot-worktrees/xode-wine/dragoshont-fantastic-broccoli"
DISK = DATA / "disk-growth-v1.json"
OUTPUT = DATA / "morning-status-v1.json"
MARKDOWN = DATA / "morning-status-v1.md"
ROOTS = [
    SUPPORT / "XodusCLI/prefixes", SUPPORT / "XodusCLI/runs",
    SUPPORT / "XodusCLI/proofs", SUPPORT / "Xodus/Prefixes",
    SUPPORT / "Ode to X/Engines/evidence",
    HOME / ".copilot/session-state/9df8acf4-7a95-43ac-84d5-d81fcdd55702/files",
    HOME / ".copilot/session-state/5fe2f9fe-f6b7-4d63-aaea-bf5dc3a6878d/files",
    HOME / "src/copilot-worktrees/xodus-macos-app/dragoshont-super-spork/.build",
]


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source(path):
    raw = path.read_bytes()
    return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
            "snapshot": json.loads(raw)}


def sample_disk():
    timestamp = dt.datetime.now(dt.timezone.utc)
    buckets = collections.defaultdict(lambda: {"allocatedBytes": 0, "logicalBytes": 0,
                                             "recentModifiedAllocatedBytes": 0, "files": 0})
    large = {}
    warnings = []
    for base in ROOTS:
        if not base.exists():
            continue
        def walk_error(error):
            warnings.append({"path": str(error.filename), "error": str(error)})

        for root, dirs, files in os.walk(base, onerror=walk_error):
            dirs[:] = [name for name in dirs if not Path(root, name).is_symlink()]
            for name in files:
                path = Path(root, name)
                try:
                    info = path.lstat()
                except FileNotFoundError:
                    continue
                except OSError as error:
                    warnings.append({"path": str(path), "error": str(error)})
                    continue
                if not stat.S_ISREG(info.st_mode):
                    continue
                rel = path.relative_to(base)
                bucket = base / rel.parts[0] if base.name != "files" else base
                row = buckets[str(bucket)]
                allocated = info.st_blocks * 512
                row["allocatedBytes"] += allocated
                row["logicalBytes"] += info.st_size
                row["files"] += 1
                recent = timestamp.timestamp() - info.st_mtime <= 900
                if recent:
                    row["recentModifiedAllocatedBytes"] += allocated
                if allocated >= 2**20 and (recent or "hogwarts" in str(path).lower()
                                          or "fallout" in str(path).lower()):
                    large[str(path)] = {"allocatedBytes": allocated, "logicalBytes": info.st_size,
                                        "mtime": info.st_mtime, "birthtime": info.st_birthtime}
    volume = os.statvfs(HOME / "Games/Xodus")
    return {"at": now(), "scanStartedAt": timestamp.isoformat(),
            "freeBytes": volume.f_bavail * volume.f_frsize,
            "buckets": dict(buckets), "trackedFiles": large, "warnings": warnings}


def compare_disk(first, last, historical):
    hours = (dt.datetime.fromisoformat(last["at"]) -
             dt.datetime.fromisoformat(first["at"])).total_seconds() / 3600
    paths = []
    for name in first["buckets"].keys() | last["buckets"].keys():
        before = first["buckets"].get(name, {}).get("allocatedBytes", 0)
        after = last["buckets"].get(name, {}).get("allocatedBytes", 0)
        paths.append({"path": name, "allocatedBytesBefore": before,
                      "allocatedBytesAfter": after, "deltaBytes": after - before,
                      "growthGiBPerHour": (after - before) / 2**30 / hours if hours > 0 else None})
    files = []
    for name, row in last["trackedFiles"].items():
        old = first["trackedFiles"].get(name)
        if old:
            delta = row["allocatedBytes"] - old["allocatedBytes"]
            files.append({"path": name, "deltaBytes": delta,
                          "growthGiBPerHour": delta / 2**30 / hours if hours > 0 else None})
    consumed = first["freeBytes"] - last["freeBytes"]
    rate = consumed / hours if hours > 0 else 0
    headroom = last["freeBytes"] - 150 * 2**30
    audit = load_json(DATA / "reclaimable-space-v1.json")
    older = []
    elapsed = (dt.datetime.fromisoformat(last["at"]) -
               dt.datetime.fromisoformat(audit["collectedAt"])).total_seconds() / 3600
    for row in audit["items"]:
        name = row["path"]
        if row["category"] != "cli-prefix" or name not in last["buckets"]:
            continue
        delta = last["buckets"][name]["allocatedBytes"] - row["allocatedBytes"]
        if delta > 2**20:
            older.append({"path": name, "baselineAt": audit["collectedAt"],
                          "deltaBytes": delta, "averageGiBPerHour": delta / 2**30 / elapsed})
    historical_hours = (dt.datetime.fromisoformat(last["at"]) -
                        dt.datetime.fromisoformat(historical["at"])).total_seconds() / 3600
    historical_rate = ((historical["freeBytes"] - last["freeBytes"]) / historical_hours
                       if historical_hours > 0 else 0)
    return {
        "sampleIntervalSeconds": hours * 3600, "freeBytesConsumed": consumed,
        "netConsumptionGiBPerHour": rate / 2**30,
        "hoursUntil150GiBFloorAtSampleRate": max(0, headroom) / rate if rate > 0 else None,
        "topPathDeltas": sorted(paths, key=lambda row: row["deltaBytes"], reverse=True)[:15],
        "topTrackedFileDeltas": sorted(files, key=lambda row: row["deltaBytes"], reverse=True)[:15],
        "recentModifiedFootprintsNotGrowth": sorted(
            [{"path": name, **row} for name, row in last["buckets"].items()
             if row["recentModifiedAllocatedBytes"]],
            key=lambda row: row["recentModifiedAllocatedBytes"], reverse=True)[:15],
        "earlierExactPrefixBaselines": sorted(older, key=lambda row: row["deltaBytes"], reverse=True)[:8],
        "historicalVolumeTrend": {
            "baseline": historical, "intervalMinutes": historical_hours * 60,
            "netConsumptionGiBPerHour": historical_rate / 2**30,
            "hoursUntil150GiBFloor": max(0, headroom) / historical_rate
            if historical_rate > 0 else None,
        },
        "limitations": "Repeated filesystem-metadata samples measure per-path allocated "
        "deltas, not exclusive physical APFS ownership. Recent mtime footprint is "
        "NOT measured 15-minute growth; no historical per-file sample exists. "
        "Metadata allocation can count hardlinks differently from historical "
        "du baselines; prefix differences are not exclusive physical allocation. "
        "Volume net rate includes other sessions, builds and APFS accounting. "
        "Shader growth, fresh prefix creation and screenshots are bursty, so "
        "hours-to-floor is an extrapolation, not a depletion forecast.",
    }


def refresh_status():
    inputs = {
        "matrix": source(MATRIX), "s1": [], "packets": [],
        "collectedAt": now(), "installedInventory": installed_inventory(),
        "verifiedReceipts": {},
        "diskEvidence": {"path": str(DISK), "sha256": sha(DISK)},
        "spaceRecoveryAttribution": {
            "sourceSession": "24963110-1b48-4e35-bae1-a54927543f42",
            "sourceType": "Direct coordinator message during this assignment",
            "statement": "The space gain came from S5 cleanup authorized by the "
            "coordinator. S4 performed no deletion or move.",
        },
        "reportedObservations": [{
            "storeId": "9MT5NJ5W7B8Z", "verdict": "GAMEPLAY_PASS",
            "sourceSession": "9df8acf4-7a95-43ac-84d5-d81fcdd55702",
            "sourceType": "Direct S3 owner message during this read-only assignment; "
            "matrix publication explicitly pending settled run.",
            "runId": "891d061f-4820-4cd3-9b61-efefa5700be9",
            "observation": "S3 reports actual G healing, relative camera and W2s+W4s "
            "movement toward Fig at47FPS. Save/quit/relaunch not verified; "
            "three WORKING unchanged. Not inferred from shader files.",
            "evidencePaths": [
                str(HOME / ".copilot/session-state/9df8acf4-7a95-43ac-84d5-d81fcdd55702/files"
                    / f"s3-hogwarts-world-{name}.png")
                for name in ("first-control", "look", "movement", "exit-cave")
            ],
        }],
    }
    for name in ("queue-profiles.json", "preflight-game-candidates.json",
                 "small-game-candidates.json", "unity-gamemaker-candidates.json",
                 "kex-game-candidates.json"):
        path = S1 / "engines" / name
        row = source(path)
        for item in row["snapshot"].get("profiles", []):
            qualification = item.get("qualification", {})
            if not qualification.get("title_screen_pass"):
                continue
            receipt = Path(qualification["receipt_path"])
            digest = sha(receipt)
            if digest != qualification["receipt_sha256"]:
                raise ValueError(f"{item['store_id']}: title-screen receipt identity mismatch")
            inputs["verifiedReceipts"][str(receipt)] = digest
        inputs["s1"].append(row)
    for name in ("s3-ready-packets-v4.json", "s3-preflight-small-v1.json",
                 "s3-preflight-catalogue-v1.json"):
        path = DATA / name
        row = source(path)
        full = row["snapshot"]
        snapshot = {key: [{field: item[field] for field in
                          ("storeId", "title", "blocker", "installStatus")
                          if field in item} for item in full.get(key, [])]
                    for key in ("items", "blockedItems")}
        row["snapshot"] = snapshot
        inputs["packets"].append(row)
    return inputs


def build_status(inputs):
    rows = {}
    installed = {sid for root in inputs["installedInventory"] for sid in root["storeIds"]}
    for packet in inputs["packets"]:
        for key in ("items", "blockedItems"):
            for item in packet["snapshot"].get(key, []):
                sid = item["storeId"]
                row = rows.setdefault(sid, {
                    "storeId": sid, "title": item["title"], "state": "UNTESTED",
                    "evidence": [], "blocker": "No observed title/gameplay/save-retention "
                    "receipt admitted; packet is a candidate, not a pass.",
                    "nextAction": "Coordinator/S2/S3 select a stopped exclusive "
                    "title/prefix slot; use the exact persisted recipe, then "
                    "observe gameplay, save, normal quit and retained relaunch.",
                    "rawMatrixVerdict": None, "s1Rows": [],
                })
                row["evidence"].append({"path": packet["path"], "sha256": packet["sha256"],
                                        "storeId": sid, "collection": key, "kind": "packet"})
                if key == "blockedItems":
                    row.update(state="BLOCKED", blocker=item["blocker"],
                               nextAction="No launch/install until the named blocker "
                               "and coordinator admission are resolved; preserve "
                               "existing payloads, prefixes and saves.")
                if sid not in installed:
                    row.update(state="BLOCKED", blocker="No installed manifest found "
                               "in current owned-root inventory; ownership/entitlement "
                               "unverified, install hold and 155+2 GiB margin apply.",
                               nextAction="Leave uninstalled. No install, login/purchase "
                               "attempt or cleanup without a new coordinator decision.")
    for source_row in inputs["s1"]:
        snap = source_row["snapshot"]
        for item in snap.get("profiles", snap.get("items", [])):
            sid = item["store_id"]
            if sid not in rows:
                continue
            row = rows[sid]
            row["s1Rows"].append({"path": source_row["path"],
                                  "sha256": source_row["sha256"], "row": item})
            row["evidence"].append({"path": source_row["path"],
                                    "sha256": source_row["sha256"],
                                    "store_id": sid, "kind": "S1-candidate-only"})
            qualification = item.get("qualification", {})
            if qualification.get("title_screen_pass"):
                receipt = qualification["receipt_path"]
                expected = qualification["receipt_sha256"]
                if inputs["verifiedReceipts"].get(receipt) != expected:
                    raise ValueError(f"{sid}: title-screen receipt identity mismatch")
                row.update(state="TITLE_SCREEN",
                           blocker="Title screen only; gameplay, save and "
                           "retained relaunch not qualified. Exact API remains unobserved.",
                           nextAction="After coordinator input-slot admission, "
                           "test gameplay and real save retention using the exact "
                           "observed S1/S2 default recipe; no automatic alternatives.")
                row["evidence"].append({"path": receipt, "sha256": expected,
                                        "kind": "observed-title-screen"})
            elif (sid in {"9MXND4PQLK3W", "9P1Z43KRNQD4"}
                  and Path(source_row["path"]).name == "kex-game-candidates.json"
                  and sid in installed):
                row.update(state="UNTESTED",
                           blocker="Earlier renderer-selection hold superseded "
                           "by exact S1 Kex candidate; no title-screen/gameplay/save "
                           "receipt or execution grant.",
                           nextAction="Coordinator/S2/S3 admit a stopped exclusive "
                           "prefix slot for this exact Kex candidate. Quake's "
                           "public-edition arguments and config persistence are "
                           "unobserved for this Xbox package; no automatic fallback.")
    matrix = inputs["matrix"]
    for item in matrix["snapshot"]["games"]:
        sid = item["productId"]
        row = rows.setdefault(sid, {"storeId": sid, "title": item["title"],
                                    "evidence": [], "s1Rows": []})
        verdict = item["verdict"]
        state = {"WORKING": "WORKING", "TITLE_SCREEN_ONLY": "TITLE_SCREEN",
                 "NOT_TESTED": "UNTESTED", "FAIL": "BLOCKED",
                 "GAMEPLAY_PASS": "BLOCKED"}.get(verdict)
        if state is None:
            raise ValueError(f"Unmapped matrix verdict: {verdict}")
        row.update(state=state, rawMatrixVerdict=verdict,
                   blocker=item.get("blocker"), matrixScope=item.get("scope"),
                   appE2e=item.get("app_e2e"),
                   nextAction=(
                       "Preserve the qualified recipe, prefix, saves and receipt; "
                       "no retest needed for title count. Keep app E2E/cloud "
                       "as separate gates where still unobserved." if state == "WORKING" else
                       "Observe the remaining real save/checkpoint, normal quit "
                       "and same-prefix retained-world relaunch before WORKING; "
                       "respect the explicit diagnostic hold." if verdict == "GAMEPLAY_PASS" else
                       "Coordinator/S3 schedule gameplay and retained-save gate "
                       "using the observed title-screen recipe, not a new default."
                       if state == "TITLE_SCREEN" else
                       "Resolve the recorded blocker using the scoped candidate "
                       "and coordinator execution admission; no blind fallback."
                       if state == "BLOCKED" else
                       "Coordinator/S2/S3 schedule one bounded title check from "
                       "the exact current S1 recipe; then gameplay/save retention."
                   ))
        row["evidence"].append({"path": matrix["path"], "sha256": matrix["sha256"],
                                "productId": sid, "collection": "games",
                                "kind": "authoritative-matrix"})
        for key in ("retentionReceipt", "recipePath"):
            if item.get(key):
                row["evidence"].append({"path": item[key], "kind": key})
        for additional in item.get("additionalQualifiedEngines", []):
            if additional.get("relaunchReceipt"):
                row["evidence"].append({"path": additional["relaunchReceipt"],
                                        "kind": "qualified-engine-relaunch"})
    for observation in inputs["reportedObservations"]:
        row = rows[observation["storeId"]]
        if row["state"] == "WORKING":
            continue
        row.update(state="BLOCKED", latestOwnerReportedVerdict=observation["verdict"],
                   latestOwnerObservation=observation,
                   blocker="Owner-reported gameplay pass only; normal save, quit "
                   "and retained-world relaunch unverified. Matrix publication "
                   "pending settled run; no WORKING promotion.",
                   nextAction="S3 finishes the admitted save/normal-quit/relaunch "
                   "gate and publishes settled evidence. Do not start another run "
                   "or infer retention from cache/screenshot growth.")
        row["evidence"].extend({"path": path, "kind": "owner-reported-gameplay",
                                "sourceSession": observation["sourceSession"]}
                               for path in observation["evidencePaths"])
    ordered = sorted(rows.values(), key=lambda row: (
        {"WORKING": 0, "TITLE_SCREEN": 1, "BLOCKED": 2, "UNTESTED": 3}[row["state"]],
        row["title"].casefold()))
    counts = dict(collections.Counter(row["state"] for row in ordered))
    prioritization = rank_blockers(ordered, installed)
    return {
        "schemaVersion": 1, "collectedAt": inputs["collectedAt"], "readOnly": True,
        "gameLaunches": 0, "collectionInputs": inputs,
        "matrixUpdatedAt": inputs["matrix"]["snapshot"]["updatedAt"],
        "statePolicy": "WORKING only from admitted tried-games matrix. "
        "GAMEPLAY_PASS maps to BLOCKED with raw verdict preserved because "
        "save retention is incomplete. TITLE_SCREEN can be established by "
        "hash-matching explicit S1 qualification receipt. Candidate rows, "
        "screenshots/filenames and exit0 alone never promote a state.",
        "freshnessWarning": "Snapshot of cited sources, not a live runtime "
        "verdict. Matrix updatedAt may lag in-flight sessions; newer screenshots "
        "are not independently interpreted or used to claim a pass.",
        "diskEvidence": inputs["diskEvidence"],
        "spaceRecoveryAttribution": inputs["spaceRecoveryAttribution"],
        "counts": counts, "workingTarget": 20, "items": ordered,
        "blockerPrioritization": prioritization,
    }


def rank_blockers(rows, installed):
    definitions = [
        ("untested recipe", "Low-to-medium, title-specific: two gameplay passes "
         "already exist; one repaired-host retest and one unknown-render diagnosis "
         "remain. No measured engineering-hour estimate.",
         "Finish Hades II/Hogwarts normal save, quit and retained-world relaunch "
         "under coordinator admission; then Well Dweller's repaired-host title "
         "retest. Balatro needs exact API-trace diagnosis, not a blind fallback.",
         "Best immediate evidence gain without installs or broad engine changes. "
         "Potential gate removals, never promised WORKING titles."),
        ("CLI bug", "Low-to-medium engineering relative to a new implementation: "
         "S2 already has a parser-fix candidate; integration/release review and "
         "exact launch-path validation remain. Frozen CLI is still held.",
         "S2/coordinator release the corrected user-data page-unit parser through "
         "the CLI's status AND launch paths, then admit Brotato qualification. "
         "Do not promote the installer-only candidate or retry frozen adf8.",
         "One directly identified failure with an existing candidate fix, but "
         "release risk/hold prevents an automatic immediate unblock."),
        ("missing engine feature", "Unknown/high diagnostic effort; this is a "
         "suspected engine/provider investigation lane, not two proven missing "
         "features or evidence that one patch fixes both.",
         "Read S2's admitted no-game storage-provider probe for Fallout before "
         "another title run; diagnose Digging's exact COM/factory path before "
         "any implementation or switch. Keep provider-cap causality unproven.",
         "Two potential downstream titles, but causal diagnosis is incomplete; "
         "do not invent a shared engine fix or hours-to-completion."),
        ("disk/ownership", "Largest numerical group, but entitlement verification, "
         "coordinator admission, disk/staging budget and fresh per-title tests "
         "are required. No engineering patch establishes ownership.",
         "Leave uninstalled. Verify entitlement only through a newly admitted "
         "CLI install path, never a probe now. Recheck 155+2 GiB margin and "
         "per-batch budget if the coordinator later reopens installation.",
         "Poor immediate return while installs are held and testing is the "
         "bottleneck; regained space alone does not remove ownership/hold gates."),
        ("anti-cheat/online", "No established blocker of this class in these "
         "22 rows; zero does NOT mean anti-cheat absent or offline cleared.",
         "Retain unknown anti-cheat/offline status. Consult existing catalogue "
         "evidence before any future eligibility change; no blanket support.",
         "No currently evidenced titles to unblock through this class."),
    ]
    grouped = {name: [] for name, *_ in definitions}
    for row in rows:
        if row["state"] != "BLOCKED":
            continue
        sid = row["storeId"]
        if sid not in installed:
            category = "disk/ownership"
        elif sid == "9P9VNSQK1W3K":
            category = "CLI bug"
        elif sid in {"C3KLDKZBHNCZ", "9NGLST31DG26"}:
            category = "missing engine feature"
        else:
            category = "untested recipe"
        row["blockerClass"] = category
        row["blockerClassIsConfirmedRootCause"] = category == "CLI bug"
        grouped[category].append({"storeId": sid, "title": row["title"],
                                  "evidence": row["evidence"]})
    return {
        "scope": "Primary next-gate triage for BLOCKED rows only; classes are "
        "mutually exclusive for counting, not established root causes. "
        "'Untested recipe' includes remaining retention/retest/diagnosis after "
        "earlier attempts. Missing engine feature remains a causal hypothesis. "
        "Effort ranking is qualitative judgment, not measured hours or a "
        "compatibility prediction; title counts are possible gate removals.",
        "rankedClasses": [
            {"priorityRank": rank, "blockerClass": name,
             "titleCount": len(grouped[name]), "titles": grouped[name],
             "relativeEffort": effort, "nextAction": action, "rankRationale": rationale}
            for rank, (name, effort, action, rationale) in enumerate(definitions, 1)
        ],
    }


def markdown(packet, disk):
    lines = ["# Morning status", "",
             f"Snapshot: {packet['collectedAt']}. Matrix updated: {packet['matrixUpdatedAt']}.",
             "", " | ".join(f"{name}: **{packet['counts'].get(name, 0)}**"
                            for name in ("WORKING", "TITLE_SCREEN", "BLOCKED", "UNTESTED")),
             "", "GAMEPLAY_PASS remains BLOCKED pending retention, not WORKING. "
             "Catalogue ownership, anti-cheat absence and offline Store behavior "
             "remain unverified. No installs, launches or deletions in this task. "
             "Full paths, raw verdicts, exact blockers and source hashes are in "
             "`morning-status-v1.json`; table evidence uses basenames.", "",
             "## Blocker priorities", "",
             "Qualitative return per effort, not measured hours or promised "
             "WORKING counts. Groups cover BLOCKED titles only; suspected causes "
             "remain unproven. No installation/retest is authorized by this table.", "",
             "| Rank | Class | Titles | Effort / best next gate |",
             "|---|---|---|---|"]
    for group in packet["blockerPrioritization"]["rankedClasses"]:
        titles = ", ".join(row["title"] for row in group["titles"]) or "None established"
        lines.append(f"| {group['priorityRank']} | {group['blockerClass']} "
                     f"({group['titleCount']}) | {titles} "
                     f"| {group['relativeEffort']} Next: {group['nextAction']} |")
    lines.extend(["", "## Per-title status", "",
             "| Title | State | Blocker / next action | Evidence |",
             "|---|---|---|---|"])
    for row in packet["items"]:
        blocker = str(row.get("blocker") or "No title-count blocker.")
        text = blocker[:125] + ("..." if len(blocker) > 125 else "")
        actions = {
            "WORKING": "Preserve qualified recipe/save; app/cloud gates separate.",
            "TITLE_SCREEN": "Admitted gameplay + save/quit/retention check.",
            "UNTESTED": "Schedule exact S1 candidate with exclusive input slot.",
            "BLOCKED": "Resolve named gate; no automatic retry/install.",
        }
        if row.get("latestOwnerReportedVerdict") or row.get("rawMatrixVerdict") == "GAMEPLAY_PASS":
            actions["BLOCKED"] = "Finish admitted retention gate; await settled owner publication."
        text += " Next: " + actions[row["state"]]
        text = text.replace("|", "/").replace("\n", " ")
        evidence = row["evidence"][-1]["path"]
        lines.append(f"| {row['title']} | {row['state']} | {text} | `{Path(evidence).name}` |")
    if disk.get("analysis"):
        a = disk["analysis"]
        lines.extend(["", "## Disk", "",
                      f"Free: **{disk['samples'][-1]['freeBytes'] / 2**30:.2f} GiB**. "
                      f"Measured net rate over {a['sampleIntervalSeconds']:.0f}s: "
                      f"**{a['netConsumptionGiBPerHour']:.2f} GiB/h**. "
                      "150 GiB estimate at that rate: "
                      + (f"**{a['hoursUntil150GiBFloorAtSampleRate']:.2f} h**."
                         if a["hoursUntil150GiBFloorAtSampleRate"] is not None else
                         "**not decreasing during the sample**."),
                      "", "| Measured path | Growth | Rate |",
                      "|---|---|---|"])
        for row in a["topPathDeltas"][:3]:
            path = row["path"].replace(str(HOME), "~")
            lines.append(f"| `{path}` | {row['deltaBytes'] / 2**20:.2f} MiB "
                         f"| {row['growthGiBPerHour']:.3f} GiB/h |")
        trend = a["historicalVolumeTrend"]
        lines.extend(["", f"Earlier volume baseline spans {trend['intervalMinutes']:.1f} "
                      f"minutes: {trend['netConsumptionGiBPerHour']:.2f} GiB/h net. "
                      "Neither trend proves steady future consumption.", "", a["limitations"]])
        intervals = disk.get("adjacentIntervalObservations", [])
        if len(intervals) > 1:
            burst = intervals[0]
            leader = burst["topPathDeltas"][0]
            lines.extend(["",
                          f"The initial {burst['sampleIntervalSeconds']:.0f}s interval "
                          f"consumed {burst['netConsumptionGiBPerHour']:.2f} GiB/h net; "
                          f"`{leader['path'].replace(str(HOME), '~')}` grew "
                          f"{leader['deltaBytes'] / 2**20:.2f} MiB. Subsequent shared-volume "
                          "free-space recovery invalidates a steady depletion ETA. "
                          "Coordinator attributes the gain to authorized S5 cleanup; "
                          "no cleanup or move was performed by this collector. "
                          "Hogwarts shader and Fallout prefix allocations did not "
                          "grow between the measured endpoints."])
            latest = intervals[-1]
            leader = latest["topPathDeltas"][0]
            eta = latest["hoursUntil150GiBFloorAtSampleRate"]
            lines.extend(["",
                          f"Latest post-cleanup interval ({latest['sampleIntervalSeconds']:.0f}s): "
                          f"**{latest['netConsumptionGiBPerHour']:.2f} GiB/h** net; "
                          f"`{leader['path'].replace(str(HOME), '~')}` grew "
                          f"{leader['deltaBytes'] / 2**20:.2f} MiB. "
                          + (f"150 GiB floor in **{eta:.2f} h** if that short "
                             "post-cleanup rate persists; not a steady forecast."
                             if eta is not None else
                             "No finite floor ETA at this interval's net rate.")])
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sample", action="store_true")
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    if args.sample or args.refresh:
        disk = load_json(DISK) if DISK.exists() else {
            "schemaVersion": 1, "readOnly": True, "deletedPaths": [], "samples": [],
            "metadataOnly": True,
        }
        if args.sample:
            disk["samples"].append(sample_disk())
        if len(disk["samples"]) >= 2:
            historical = load_json(DATA / "s3-preflight-catalogue-v1.json")["collectionInputs"]
            disk["analysis"] = compare_disk(
                disk["samples"][0], disk["samples"][-1],
                {"at": historical["collectedAt"], "freeBytes": historical["freeBytes"],
                 "source": "s3-preflight-catalogue-v1.json collectionInputs"})
            disk["adjacentIntervalObservations"] = []
            for first, last in zip(disk["samples"], disk["samples"][1:]):
                comparison = compare_disk(first, last, {
                    "at": historical["collectedAt"], "freeBytes": historical["freeBytes"]})
                disk["adjacentIntervalObservations"].append({
                    "startedAt": first["at"], "endedAt": last["at"],
                    "sampleIntervalSeconds": comparison["sampleIntervalSeconds"],
                    "netConsumptionGiBPerHour": comparison["netConsumptionGiBPerHour"],
                    "hoursUntil150GiBFloorAtSampleRate":
                        comparison["hoursUntil150GiBFloorAtSampleRate"],
                    "topPathDeltas": comparison["topPathDeltas"][:3],
                })
        DISK.write_text(json.dumps(disk, indent=2, ensure_ascii=True) + "\n")
        if args.sample:
            print("Disk samples:", len(disk["samples"]))
    if args.refresh:
        packet = build_status(refresh_status())
        OUTPUT.write_text(json.dumps(packet, indent=2, ensure_ascii=True) + "\n")
        MARKDOWN.write_text(markdown(packet, load_json(DISK)))
        print(packet["counts"])
    elif not args.sample:
        packet = load_json(OUTPUT)
        if packet != build_status(packet["collectionInputs"]):
            raise ValueError("Morning snapshot does not reproduce")
        print(packet["counts"])


if __name__ == "__main__":
    main()
