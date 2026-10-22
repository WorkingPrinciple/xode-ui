#!/usr/bin/env python3
"""Execute only the coordinator's exact seven-prefix cleanup grant."""

import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess

from inspect_queue import DATA

ROOT = Path.home() / "Library/Application Support/XodusCLI/prefixes"
NAMES = (
    "s2-small-9MSVVM5NS9L6-creation-dx11-d3dmetal-passive-v1",
    "s2-balatro-apple4-exit-v1",
    "s3-balatro-free-v1",
    "s2-small-9PLH7R84GJWP-welldweller-d3dmetal-passive-v1",
    "s3-well-cross-26-3",
    "s3-well-d3dmetal-v1",
    "s3-well-dxmt",
)
OUTPUT = DATA / "parked-prefix-cleanup-v1.json"


def free_bytes():
    volume = os.statvfs(ROOT)
    return volume.f_bavail * volume.f_frsize


def main():
    if OUTPUT.exists():
        raise RuntimeError("Receipt exists; never replay cleanup")
    rows = []
    for name in NAMES:
        path = ROOT / name
        if not path.is_dir() or path.is_symlink() or path.resolve() != path:
            raise RuntimeError(f"Exact authorized directory missing or redirected: {path}")
        handles = subprocess.run(["/usr/sbin/lsof", "-nP", "+D", str(path)],
                                 capture_output=True, text=True)
        if handles.returncode != 1 or handles.stdout or handles.stderr:
            raise RuntimeError(f"Cannot establish unused prefix: {path}")
        allocated = int(subprocess.check_output(
            ["/usr/bin/du", "-sk", str(path)], text=True).split()[0]) * 1024
        rows.append({"path": str(path), "allocatedBytesBefore": allocated,
                     "lsof": "exit 1, empty stdout/stderr", "deleted": False})
    processes = subprocess.check_output(["/bin/ps", "eww", "-axo", "pid=,command="], text=True)
    if any(row["path"] in processes for row in rows):
        raise RuntimeError("Process command/environment references an authorized prefix")
    receipt = {
        "schemaVersion": 1, "startedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "authorization": "User-directed via coordinator 2026-10-22T06:07:18.672Z: all seven "
        "exact parked DREDGE/Balatro/Well directories; router confirms no active packet/queue "
        "or retries, scoped exclusive ownership S4.",
        "historicalPacketReferences": "Retained historical packets reference DREDGE/Well. "
        "Coordinator explicitly retired active use; historical evidence remains unchanged.",
        "freeBytesBefore": free_bytes(), "items": rows, "completed": False,
        "preserved": "All proofs/logs/receipts/screenshots/game installs and lifecycle lock "
        "files outside the seven directories; symlink targets never followed.",
    }
    OUTPUT.write_text(json.dumps(receipt, indent=2) + "\n")
    for row in rows:
        path = Path(row["path"])
        handles = subprocess.run(["/usr/sbin/lsof", "-nP", "+D", str(path)],
                                 capture_output=True, text=True)
        if handles.returncode != 1 or handles.stdout or handles.stderr:
            raise RuntimeError(f"Prefix became active; partial receipt retained: {path}")
        shutil.rmtree(path)
        row["deleted"] = not path.exists()
        if not row["deleted"]:
            raise RuntimeError(f"Deletion did not remove exact path: {path}")
        OUTPUT.write_text(json.dumps(receipt, indent=2) + "\n")
    receipt.update(completed=True, completedAt=dt.datetime.now(dt.timezone.utc).isoformat(),
                   allocatedBytesRemoved=sum(row["allocatedBytesBefore"] for row in rows),
                   freeBytesAfter=free_bytes())
    receipt["observedVolumeFreeDeltaBytes"] = receipt["freeBytesAfter"] - receipt["freeBytesBefore"]
    receipt["deltaCaveat"] = "Shared volume/APFS delta is observed, not guaranteed attributable physical reclaim."
    OUTPUT.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
