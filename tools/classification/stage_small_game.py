#!/usr/bin/env python3
"""Install exactly one authorized small title; no launch, login or deletion."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid

from build_ready_packets import CLI_SHA
from build_preflight_packets import validate_status
from inspect_queue import DATA, SIGNATURES, inspect_package, load_json

INSTALLER_SHA = "ffc4aa3040394dd5ae679f665e522f5ead12c92da20376942e9508dc0d4f060d"
BROTATO_INSTALLER_SHA = "ebd56e56a23cdd73de884e80d4288eed6014a40435e7253c49a0cf42f8803fe3"
OUTPUT = DATA / "small-game-staging-v1.json"
ROOTS = {
    "9P9VNSQK1W3K": "Brotato-Xbox",
    "9P8NSTDMZ11P": "Inscryption-Xbox",
    "9MSVVM5NS9L6": "Dredge-Xbox",
    "9PBWWQGXVMKC": "MonsterSanctuary-Xbox",
    "9NLRT31Z4RWM": "Tunic-Xbox",
    "9NMNMS626R59": "HallsOfTorment-Xbox",
    "9PD5BM2Z8C4L": "VampireSurvivors-Xbox",
    "9P1Z43KRNQD4": "Quake-Xbox",
    "9MXND4PQLK3W": "Doom64-Xbox",
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def free_bytes():
    stat = os.statvfs(Path.home() / "Games/Xodus")
    return stat.f_bavail * stat.f_frsize


def write(data):
    temporary = OUTPUT.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(data, indent=2, ensure_ascii=True) + "\n")
    temporary.replace(OUTPUT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("store_id", choices=ROOTS)
    parser.add_argument("--resume-brotato", action="store_true",
                        help="Explicit coordinator-approved partial resume with S2 installer-only candidate")
    args = parser.parse_args()
    support = Path.home() / "Library/Application Support"
    if args.resume_brotato and args.store_id != "9P9VNSQK1W3K":
        raise ValueError("Resume exception is Brotato only")
    installer_sha = BROTATO_INSTALLER_SHA if args.resume_brotato else INSTALLER_SHA
    cli = support / f"Ode to X/Service/candidates/{installer_sha}/xodus-cli"
    status_cli = support / f"Ode to X/Service/candidates/{CLI_SHA}/xodus-cli"
    if sha(cli) != installer_sha or sha(status_cli) != CLI_SHA:
        raise ValueError("Immutable installer/status identity mismatch")
    matrix_path = Path("/Users/dragoshont/.copilot/session-state/"
                       "24963110-1b48-4e35-bae1-a54927543f42/files/s3-tried-games.json")
    if args.store_id in {row["productId"] for row in load_json(matrix_path)["games"]}:
        raise ValueError("Title already in authoritative matrix")
    row, = [row for row in load_json(DATA / "small-game-evidence-v1.json")["items"]
            if row["storeId"] == args.store_id]
    size = row["downloadSizeBytes"]
    if not 0 < size <= 8 * 2**30:
        raise ValueError("Unknown/oversized download")
    data = load_json(OUTPUT) if OUTPUT.exists() else {
        "schemaVersion": 1, "scope": "Serial installs only; no launches or deletion",
        "budgetBytes": 20 * 2**30, "minimumFreeBytes": 150 * 2**30,
        "installerSha256": INSTALLER_SHA, "statusCliSha256": CLI_SHA, "items": [],
    }
    data["operationalMinimumFreeBytes"] = 155 * 2**30
    if not any(item["storeId"] == "9P9VNSQK1W3K" for item in data["items"]):
        prior = support / "XodusCLI/runs/8c15b0b5-2f15-4a5d-a5a5-7d026453a1ff/result.json"
        if prior.is_file():
            receipt = load_json(prior)
            if receipt["product"] != "9P9VNSQK1W3K" or receipt["success"]:
                raise ValueError("Unexpected prior Brotato attempt")
            data["items"].insert(0, {
                "storeId": receipt["product"], "title": "Brotato",
                "root": receipt["game_dir"], "state": "failed-parser-panic",
                "install": receipt, "reservedBytes": 449249280,
                "stopPipeline": False, "hold": "S2 owns UTF-16 parser diagnosis; no retry/deletion.",
                "source": str(prior),
            })
    prior_attempts = [item for item in data["items"] if item["storeId"] == args.store_id]
    resume = args.resume_brotato and len(prior_attempts) == 1 and (
        prior_attempts[0]["state"] == "failed-parser-panic")
    if args.resume_brotato and not resume:
        raise ValueError("Only the recorded preserved parser-failure partial may resume once")
    if prior_attempts and not resume:
        raise ValueError("Existing attempt; reconcile with owner instead of retrying")
    if any(item.get("stopPipeline") for item in data["items"]):
        raise ValueError("Pipeline held by earlier login/purchase/disk gate")
    root = Path.home() / "Games/Xodus" / ROOTS[args.store_id]
    if root.exists() and not resume:
        raise ValueError("Payload path already exists; no overwrite/resume")
    if resume and (not root.is_dir() or root.is_symlink() or root.resolve() != root):
        raise ValueError("Preserved Brotato partial identity changed")
    consumed = sum(item["reservedBytes"] for item in data["items"])
    before = free_bytes()
    if (consumed + size > data["budgetBytes"]
            or before - size - 2 * 2**30 < data["operationalMinimumFreeBytes"]):
        raise ValueError("20 GiB budget or updated 155 GiB operational floor "
                         "+ 2 GiB staging margin does not fit")
    state_dir = support / "XodusCLI"
    if resume:
        state_dir = state_dir / "proofs" / f"s4-brotato-ebd56e-{uuid.uuid4().hex}"
        if state_dir.exists():
            raise ValueError("Resume requires a new absent proof directory")
    argv = [str(cli), "install", args.store_id, "--account-profile", "--game-dir",
            str(root), "--state-dir", str(state_dir)]
    if not resume:
        argv.extend(["--market", "GB"])
    record = {
        "storeId": args.store_id, "title": row["title"], "root": str(root),
        "reservedBytes": size, "freeBeforeBytes": before,
        "startedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "argv": argv, "stopPipeline": True, "state": "installing-or-unreconciled",
        "matrixSha256": sha(matrix_path),
        "installerSha256": installer_sha, "resumesPreservedPartial": resume,
    }
    data["items"].append(record)
    write(data)
    print(f"Admitted {row['title']}; free {before / 2**30:.2f} GiB", flush=True)
    process = subprocess.run(argv, capture_output=True, text=True, timeout=2700)
    record.update(processExitCode=process.returncode, freeAfterBytes=free_bytes(),
                  finishedAt=dt.datetime.now(dt.timezone.utc).isoformat(),
                  stderr=process.stderr)
    receipt = json.loads(process.stdout)
    record["install"] = receipt
    prompt = receipt.get("popups") or receipt.get("error_code") in {
        "SIGN_IN_REQUIRED", "ACCOUNT_REQUIRED", "PURCHASE_REQUIRED", "ENTITLEMENT_REQUIRED",
    } or re.search(r"sign.?in required|log.?in required|purchase required|"
                   r"reauth|authentication required|not entitled",
                   str(receipt.get("error", "")), re.I)
    record["stopPipeline"] = True
    record["state"] = "failed"
    write(data)
    if (receipt.get("product") != args.store_id or receipt.get("game_dir") != str(root)
            or receipt.get("operation") != "install"):
        raise ValueError("Install receipt identity mismatch; pipeline held")
    if prompt:
        raise RuntimeError("Login/purchase prompt reported; pipeline held, no re-auth")
    if process.returncode or not receipt.get("success"):
        raise RuntimeError(f"Install failed; recorded {receipt.get('run_id')}; no automatic retry")
    record["state"] = "installed-awaiting-status"
    write(data)
    status_argv = [str(status_cli), "install-status", args.store_id, "--game-dir", str(root),
                   "--state-dir", str(support / "XodusCLI")]
    status = subprocess.run(status_argv, capture_output=True, text=True, check=False, timeout=300)
    record["statusAttempt"] = {"argv": status_argv, "processExitCode": status.returncode,
                               "stdout": status.stdout, "stderr": status.stderr}
    record["statusArgv"] = status_argv
    record["state"] = "installed-status-blocked"
    write(data)
    status.check_returncode()
    record["installStatus"] = json.loads(status.stdout)
    validate_status({"storeId": args.store_id, "gameDir": str(root)}, record["installStatus"])
    record["package"] = inspect_package(
        {"storeId": args.store_id, "installRoot": str(root)},
        load_json(SIGNATURES)["signatures"],
    )
    record["allocatedBytes"] = int(subprocess.run(
        ["/usr/bin/du", "-sk", str(root)], capture_output=True, text=True, check=True,
    ).stdout.split()[0]) * 1024
    record["reservedBytes"] = max(size, record["allocatedBytes"])
    record["freeAfterBytes"] = free_bytes()
    record["state"] = "complete-not-game-qualified"
    record["stopPipeline"] = record["freeAfterBytes"] < data["operationalMinimumFreeBytes"] or (
        sum(item["reservedBytes"] for item in data["items"]) > data["budgetBytes"])
    write(data)
    print(args.store_id, "complete", record["installStatus"].get("files_total"),
          "freeGiB", round(record["freeAfterBytes"] / 2**30, 2))


if __name__ == "__main__":
    main()
