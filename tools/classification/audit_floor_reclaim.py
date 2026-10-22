#!/usr/bin/env python3
"""Read-only exact-path reclaim proposal; never deletes or authorizes deletion."""

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess

from inspect_queue import DATA

HOME = Path.home()
CLI = HOME / "Library/Application Support/XodusCLI"
ROOT = Path(__file__).resolve().parents[2]
OUTPUT = DATA / "floor-reclaim-v1.json"


def size(path):
    result = subprocess.run(["/usr/bin/du", "-sk", str(path)],
                            capture_output=True, text=True, check=True)
    return int(result.stdout.split()[0]) * 1024


def main():
    now = dt.datetime.now(dt.timezone.utc)
    sources = []
    for batch in ("passive-small-eight-v1", "passive-batch2-eight-v1",
                  "passive-batch3-eight-v1"):
        path = CLI / "proofs" / batch / "packets.json"
        raw = path.read_bytes()
        sources.append({"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
                        "text": raw.decode()})
    owners = DATA / "path-to-20-owner-verdicts-v1.json"
    sources.append({"path": str(owners), "text": owners.read_text(),
                    "sha256": hashlib.sha256(owners.read_bytes()).hexdigest()})
    rows = []
    for path in sorted((CLI / "runs").iterdir()):
        receipt = path / "result.json"
        if not path.is_dir() or path.is_symlink() or not receipt.is_file():
            continue
        result = json.loads(receipt.read_text())
        finished = result.get("finished_at")
        if not finished or (now - dt.datetime.fromisoformat(finished)).total_seconds() <= 7200:
            continue
        progress = path / "progress.jsonl"
        if not progress.is_file() or progress.is_symlink():
            continue
        allocated = size(progress)
        if allocated <= 100_000_000:
            continue
        rows.append({"path": str(progress), "allocatedBytes": allocated, "owner": "S2",
                     "category": "retained install evidence, NOT staging",
                     "safeCandidate": False, "deleteAuthorized": False,
                     "finishedAt": finished, "productId": result.get("product"),
                     "receiptRetain": str(receipt),
                     "receiptSha256": hashlib.sha256(receipt.read_bytes()).hexdigest(),
                     "reason": "S2 owner explicitly holds all runs/proofs. Temporary mounted "
                     "HFS staging was already ejected. Do not discard retained progress evidence."})
    build = ROOT / ".build/out"
    references = [row["path"] for row in sources if str(build) in row["text"]]
    if build.exists():
        handles = subprocess.run(["/usr/sbin/lsof", "-nP", "+D", str(build)],
                                 capture_output=True, text=True)
        if handles.returncode not in (0, 1) or handles.stderr:
            raise RuntimeError("Cannot establish build quiescence: " + handles.stderr)
        rows.append({"path": str(build), "allocatedBytes": size(build), "owner": "S4",
                 "category": "rebuildable Swift check products/compiler intermediates",
                 "safeCandidate": not references and handles.returncode == 1,
                 "deleteAuthorized": False, "openHandles": handles.stdout.splitlines(),
                 "packetReferences": references,
                 "reason": "S4-owned local Swift management checks output, not release candidates. "
                 "No local-candidates subtree; .build/debug is only a symlink into this directory. "
                 "Checks already completed, no open handles at sample. Rebuildable with Swift. "
                 "Not referenced by three frozen queued packets or owner verdict metadata."})
    s5 = HOME / "src/copilot-worktrees/xodus-macos-app/dragoshont-super-spork/.build/out"
    rows.append({"path": str(s5), "allocatedBytes": size(s5) if s5.exists() else 0,
                 "existsAtSample": s5.exists(), "owner": "S5 / dragoshont",
                 "category": "rebuildable compiler output, owner-confirmed",
                 "safeCandidate": s5.exists(), "deleteAuthorized": False,
                 "reason": "S5 direct report: root .build/out only, no active build/open files; "
                 "not release candidate or live app input. Rebuild via swift build/tools/check.sh. "
                 "Owner/coordinator deletion approval still required. All nested source/.build/out "
                 "under local-candidates/retained release evidence remain protected. "
                 "If absent at sample, no remaining reclaim credited."})
    volume = os.statvfs(ROOT)
    cleanup_path = DATA / "floor-reclaim-s4-cleanup-v1.json"
    cleanup = json.loads(cleanup_path.read_text()) if cleanup_path.exists() else None
    packet = {"schemaVersion": 1, "collectedAt": now.isoformat(),
              "freeBytes": volume.f_bavail * volume.f_frsize, "thresholdBytes": 100_000_000,
              "deletedPaths": [], "priorAuthorizedCleanup": cleanup,
              "sources": [{k: v for k, v in row.items() if k != "text"}
                                            for row in sources],
              "referenceScope": "Three frozen passive packet files plus owner-verdict metadata; "
              "not exhaustive runtime reference proof. Recheck processes immediately before "
              "any separately approved deletion.",
              "items": rows,
              "prefixDisposition": "No owner-cleared >100MB abandoned prefix established. "
              "S2 holds pass/comparison/pending prefixes; LIMBO failed prefix already removed "
              "and yields zero new reclaim. Age or absence from frozen packets alone is not safety.",
              "duplicatesDisposition": "No owner-cleared byte-identical redundant evidence "
              "copy established. Proofs/retained release evidence remain held.",
              "s2OwnerReportAt": "2026-10-22T05:55Z",
              "policy": "Proposal only, no deletion authorization. Allocated bytes are not "
              "guaranteed physical APFS reclaim. Never delete parent runs, .build root, "
              "release candidates, proofs, saves, payloads or linked targets."}
    OUTPUT.write_text(json.dumps(packet, indent=2) + "\n")
    lines = ["# Disk-floor reclaim proposal", "", f"Read-only sample {packet['collectedAt']}; "
             f"free **{packet['freeBytes']/2**30:.3f} GiB**. No further deletion authorized.", "",
             "| Exact path | Allocated MB / GiB | Owner | Disposition / safety basis |",
             "|---|---|---|---|"]
    for row in rows:
        lines.append(f"| `{row['path']}` | {row['allocatedBytes']/1e6:.2f} / "
                     f"{row['allocatedBytes']/2**30:.3f} | {row['owner']} | "
                     f"{'PROPOSAL: owner-safe rebuildable output' if row['safeCandidate'] else 'HOLD'}"
                     f": {row['reason']} |")
    lines.extend(["", packet["prefixDisposition"], "", packet["duplicatesDisposition"], "",
                  packet["referenceScope"], "", packet["policy"], "",
                  "Retain every run result.json/events/stdout/stderr receipt. The large run "
                  "children above are progress evidence, not payload staging. JSON retains "
                  "completion dates and result receipt hashes. S5 explicitly identified only "
                  "its root .build/out as a rebuildable candidate; no deletion authorized for it."])
    if cleanup:
        lines.extend(["", "## Completed separate authorization", "",
                      "Coordinator explicitly authorized only S4's unused `.build/out`. "
                      f"Removed {cleanup['allocatedBytesBefore']/1e6:.2f} MB allocated after "
                      "exact-path/non-symlink and empty lsof checks; absence verified. "
                      "All logs/evidence retained. Cleanup receipt: "
                      "`floor-reclaim-s4-cleanup-v1.json`. S5 output was already absent "
                      "when sampled; no additional S5 reclaim credited."])
    (DATA / "floor-reclaim-v1.md").write_text("\n".join(lines) + "\n")
    print("freeGiB", packet["freeBytes"]/2**30, "safeBytes",
          sum(row["allocatedBytes"] for row in rows if row["safeCandidate"]))


if __name__ == "__main__":
    main()
