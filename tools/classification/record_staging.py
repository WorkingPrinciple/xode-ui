#!/usr/bin/env python3
"""Bind successful install receipts to fresh, read-only completeness and package checks."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import subprocess
from pathlib import Path

from inspect_queue import DATA, SIGNATURES, inspect_package, load_json


OUTPUT = DATA / "install-staging-v1.json"


def sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, action="append", required=True)
    parser.add_argument("--status-cli", type=Path, required=True)
    parser.add_argument("--status-sha256", required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--profiles", type=Path, required=True)
    args = parser.parse_args()
    cli = args.status_cli.resolve(strict=True)
    cli_hash = sha256(cli)
    if cli_hash != args.status_sha256:
        raise RuntimeError("Status executable does not match the S2-provided SHA-256")
    signatures = load_json(SIGNATURES)
    profiles = load_json(args.profiles)["items"]
    if not isinstance(profiles, list):
        raise RuntimeError("S1 queue profile items must be a list")
    by_id = {profile["store_id"]: profile for profile in profiles}
    data = load_json(OUTPUT) if OUTPUT.exists() else {
        "schemaVersion": 1,
        "products": {},
        "scope": "Installation and static package evidence only; no game launches or runtime qualification.",
    }
    root_parent = (Path.home() / "Games/Xodus").resolve(strict=True)
    for receipt_path in args.receipt:
        receipt = load_json(receipt_path)
        product_id = receipt["product"]
        if (
            receipt.get("operation") != "install"
            or receipt.get("success") is not True
            or receipt.get("exit_code") != 0
        ):
            raise RuntimeError(f"{product_id}: receipt is not a successful installation")
        root = Path(receipt["game_dir"]).resolve(strict=True)
        if not root.is_relative_to(root_parent) or root == root_parent:
            raise RuntimeError(f"{product_id}: package root is outside the authorized game directory")
        if sha256(cli) != cli_hash:
            raise RuntimeError("Status executable changed before inspection")
        process = subprocess.run(
            [str(cli), "install-status", product_id, "--game-dir", str(root),
             "--state-dir", str(args.state_dir)],
            capture_output=True, text=True, check=False,
        )
        if process.returncode != 0:
            raise RuntimeError(
                f"{product_id}: install-status exit {process.returncode}; "
                f"stdout={process.stdout}; stderr={process.stderr}"
            )
        status = json.loads(process.stdout)
        if sha256(cli) != cli_hash:
            raise RuntimeError("Status executable changed during inspection")
        if (
            status.get("operation") != "install-status"
            or status.get("product") != product_id
            or Path(status["game_dir"]).resolve() != root
            or status.get("status") != "complete"
            or status.get("success") is not True
        ):
            raise RuntimeError(f"{product_id}: completeness not established: {process.stdout}")
        package = inspect_package(
            {"storeId": product_id, "installRoot": "~/" + root.relative_to(Path.home()).as_posix()},
            signatures["signatures"],
        )
        queue_path = DATA / "next-30-queue.json"
        inspection_path = DATA / "queue-inspection-v1.json"
        queue = load_json(queue_path)
        inspection = load_json(inspection_path)
        item = next(row for row in queue["items"] if row["storeId"] == product_id)
        proposal = {
            "DX11": "creation-dx11-d3dmetal",
            "DX12": "apple-gptk-4.0b3",
            "DX9": "queue-winecx-nativejson",
            "OpenGL": "queue-winecx-nativejson",
        }.get(item["api"])
        proposal_basis = f"queue API {item['api']}; {item['apiBasis']}"
        if proposal is None and "OpenGL" in package["graphicsAPIs"]:
            proposal = "queue-winecx-nativejson"
            proposal_basis = (
                "Readable package renderer imports OpenGL; active renderer unverified. "
                f"Public queue API remains {item['api']}."
            )
        profile = by_id.get(product_id)
        data["products"][product_id] = {
            "root": "~/" + root.relative_to(Path.home()).as_posix(),
            "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "install": {
                key: receipt.get(key) for key in (
                    "run_id", "product", "started_at", "finished_at", "success", "exit_code",
                )
            },
            "installReceiptPath": str(receipt_path),
            "completeness": status,
            "statusExecutable": str(cli),
            "statusExecutableSha256": cli_hash,
            "package": package,
            "signatureSet": SIGNATURES.name,
            "signatureSetSha256": sha256(SIGNATURES),
            "engineProfileSource": str(args.profiles),
            "engineProfile": profile,
            "engineProfileStatus": "candidate-not-game-qualified" if profile else "pending-S1-binding",
            "engineProfileProposal": {
                "profile": proposal,
                "status": "proposal-awaiting-S1-confirmation",
                "basis": proposal_basis,
                "scope": "Not an approved binding or a runtime/gameplay result.",
            } if proposal and not profile else None,
        }
        OUTPUT.write_text(
            json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        item["alreadyInstalled"] = True
        item["installRoot"] = data["products"][product_id]["root"]
        item["sizeBytes"] = sum(
            path.stat().st_size for path in root.rglob("*")
            if path.is_file() and not path.is_symlink()
        )
        item["sizeKnown"] = item["sizeBytes"] > 0
        item["sizeBasis"] = "sum of local file sizes in the installed root; not download size"
        item["installNote"] = "Installer success and fresh signed CLI install-status=complete; not a gameplay pass."
        item["installStatus"] = "complete"
        item["stagingEvidence"] = f"{OUTPUT.name}#/products/{product_id}"
        item["apiAlternatives"] = package["graphicsAPIs"]
        item["engine"] = list(package["engineMarkers"])
        item["signInEvidence"].update(
            manifestFields=package["metadata"],
            hasXboxIdentity=package["hasXboxIdentity"],
            packageInspected=True,
            basis="manifest-insufficient",
        )
        item["antiCheatScanStatus"] = (
            "named-match" if package["antiCheatScan"]["matches"] else "no-known-path-signature"
        )
        inspection["products"][product_id]["package"] = package
        for path, updated in ((queue_path, queue), (inspection_path, inspection)):
            path.write_text(
                json.dumps(updated, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
        print(product_id, "complete", status["files_total"], "files;",
              profile["profile"] if profile else "engine-profile-pending")


if __name__ == "__main__":
    main()
