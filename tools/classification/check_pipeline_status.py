#!/usr/bin/env python3
"""Inspect existing pipeline payloads and account collection, without acquisition."""

import asyncio
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

from inspect_queue import DATA
from read_catalogue_ownership import BINARY, IDENTITY, now, read_collection


async def main():
    if hashlib.sha256(BINARY.read_bytes()).hexdigest() != IDENTITY:
        raise ValueError("Frozen CLI identity mismatch")
    ranked = DATA / "remaining-candidates-ranked-v1.json"
    candidates = [row for row in json.loads(ranked.read_text())["items"]
                  if row["pipelineExtensionCandidate"]]
    first = ["9NQVHHW88XW9", "9PJPCB188SVG"]
    candidates.sort(key=lambda row: (first.index(row["storeId"])
                                    if row["storeId"] in first else row["rank"]))
    proof = Path.home() / "Library/Application Support/XodusCLI/proofs" / (
        "s4-pipeline-status-" + uuid.uuid4().hex)
    proof.mkdir()
    collection = await read_collection(proof / "account-state")
    raw = proof / "account-collection.json"
    raw.write_text(json.dumps(collection, indent=2) + "\n")
    grants = {row["productID"]: row["acquisitionKind"] for row in
              collection.get("collection", {}).get("payload", {}).get("items", [])}
    rows = []
    for candidate in candidates:
        sid = candidate["storeId"]
        root = candidate["inventoryEvidence"]["root"]
        argv = [str(BINARY), "install-status", sid, "--game-dir", root,
                "--state-dir", str(proof / "status-state")]
        result = subprocess.run(argv, capture_output=True, text=True, timeout=300)
        log = proof / (sid + "-install-status.json")
        log.write_text(result.stdout)
        (proof / (sid + "-stderr.log")).write_text(result.stderr)
        status = json.loads(result.stdout) if result.stdout.strip() else None
        kind = grants.get(sid)
        rows.append({
            "storeId": sid, "title": candidate["title"], "root": root,
            "checkedAt": now(), "processExitCode": result.returncode,
            "installStatus": status,
            "installStatusReceipt": {"path": str(log),
                                     "sha256": hashlib.sha256(log.read_bytes()).hexdigest()},
            "entitlement": kind if collection.get("complete") and kind else "unknown",
            "entitlementBasis": "Exact account-bound Collections grant if returned; absence "
            "does not deny subscription access. Local payload is not an entitlement.",
            "launchAuthorized": False, "acquisitionAttempted": False,
        })
    packet = {
        "schemaVersion": 1, "checkedAt": now(), "cliSha256": IDENTITY,
        "rankedSource": {"path": str(ranked),
                         "sha256": hashlib.sha256(ranked.read_bytes()).hexdigest()},
        "accountReadComplete": collection.get("complete") is True,
        "accountReadError": collection.get("error"),
        "accountProductCount": len(grants),
        "privateAccountReceipt": {"path": str(raw),
                                  "sha256": hashlib.sha256(raw.read_bytes()).hexdigest()},
        "scope": "Read-only install-status plus existing account library. No sign-in, "
        "license/key acquisition, purchase, download, install, game or screen operation.",
        "entitlementBlocker": "S2 source review: no non-acquiring entitlement check exists. "
        "ode-package-check performs device/silent user token exchanges and a live content-license "
        "request, despite no local key persistence or launch. Coordinator approval required "
        "before one exact package check per title; not executed.",
        "ownerEvidence": {
            "sourceSession": "5fe2f9fe-f6b7-4d63-aaea-bf5dc3a6878d",
            "source": "S2 report: crates/xodus-cli/src/ode_package_check.rs and license.rs",
            "subnauticaInstallRun": "2abbb818",
            "subnauticaInstallMeaning": "Account-bound successful package installation, not license proof.",
            "blueyInstallReceipt": "Not found by S2; install-status complete only.",
        },
        "items": rows,
    }
    (DATA / "pipeline-install-entitlement-v1.json").write_text(
        json.dumps(packet, indent=2) + "\n")
    print("Account complete:", packet["accountReadComplete"], "products:", len(grants))
    for row in rows:
        print(row["title"], row["processExitCode"], row["entitlement"],
              row["installStatus"])


if __name__ == "__main__":
    asyncio.run(main())
