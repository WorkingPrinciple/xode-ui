#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Sends WM_CLOSE to one running game through its own run's Wine and prefix, and records a receipt.

Reads `<run>/launch-command.json` for the exact Wine binary and WINEPREFIX, runs
`wine taskkill /im <exe>` (never `/f`), waits for the run's `finished` event, and writes
`<evidence>/quit-receipt.json`. The receipt keeps the WINEPREFIX only as a SHA-256 so no
local path is recorded.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

EXE = re.compile(r"[A-Za-z0-9 ._()-]{1,128}\.exe")


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def launch_child(run_dir):
    child = json.loads((run_dir / "launch-command.json").read_text())["child"]
    argv, environment = child["argv"], child["environment"]
    if len(argv) < 4 or argv[1] != "run" or not argv[3].endswith("/bin/wine"):
        raise ValueError("Unexpected launch command shape")
    prefix = environment.get("WINEPREFIX")
    if not prefix:
        raise ValueError("Launch command has no WINEPREFIX")
    return argv[3], prefix


def finished(run_dir):
    events = run_dir / "events.jsonl"
    if not events.exists():
        return None
    for line in events.read_text().splitlines():
        event = json.loads(line)
        if event.get("event") == "finished":
            return event
    return None


def close(run_dir, exe, evidence, wait_seconds):
    if not EXE.fullmatch(exe):
        raise ValueError("Executable name must be a plain .exe file name")
    wine, prefix = launch_child(run_dir)
    command = [wine, "taskkill", "/im", exe]
    environment = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "WINEPREFIX": prefix,
                   "WINEDEBUG": "-all"}
    # CrossOver's wine wrapper ignores WINEPREFIX and looks for a named bottle; point it at the run's prefix.
    if "/CrossOver.app/" in wine:
        environment["CX_BOTTLE_PATH"] = os.path.dirname(prefix)
        environment["CX_BOTTLE"] = os.path.basename(prefix)
    sent_at = utc_now()
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=60)
    deadline = time.monotonic() + wait_seconds
    event = finished(run_dir)
    while event is None and time.monotonic() < deadline:
        time.sleep(2)
        event = finished(run_dir)
    output = [line for line in result.stdout.splitlines() if line.strip()]
    receipt = {
        "schema": "xode.quit-receipt.v1",
        "run": run_dir.name,
        "method": "WM_CLOSE",
        "command": ["<wine>", "taskkill", "/im", exe],
        "wineBinarySha256": hashlib.sha256(Path(wine).read_bytes()).hexdigest(),
        "winePrefixSha256": hashlib.sha256(prefix.encode()).hexdigest(),
        "taskkillExitCode": result.returncode,
        "taskkillOutput": output[-1][:200] if output else None,
        "sentAt": sent_at,
        "finishedObservedAt": utc_now() if event else None,
        "runExitCode": event.get("exit_code") if event else None,
    }
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "quit-receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--exe", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--wait-seconds", type=int, default=120)
    args = parser.parse_args()
    receipt = close(args.run_dir, args.exe, args.evidence, args.wait_seconds)
    print(json.dumps({key: receipt[key] for key in ("taskkillExitCode", "runExitCode", "winePrefixSha256")}))
    return 0 if receipt["runExitCode"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
