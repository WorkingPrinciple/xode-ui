#!/usr/bin/env python3
"""Import existing S2 receipts only; never request a license."""

import hashlib
import json
from pathlib import Path

from inspect_queue import DATA

RECEIPTS = {
    "s2-entitlement-package-check-v1": "e3624c1c47935f570e628145d2a39a113ebc372b95c1946857868f8563b075a7",
    "s2-entitlement-package-check-seven-v1": "9b20e4a22f75e98e2617d760ce021762893ee81bcdb8b7ea372dd743a1b69dd0",
}


def main():
    output = DATA / "pipeline-install-entitlement-v1.json"
    packet = json.loads(output.read_text())
    rows = {row["storeId"]: row for row in packet["items"]}
    seen = set()
    for directory, expected in RECEIPTS.items():
        path = Path.home() / "Library/Application Support/XodusCLI/proofs" / directory / "receipt.json"
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError("S2 license receipt hash mismatch")
        receipt = json.loads(raw)
        for check in receipt["checks"]:
            sid = check["product"]
            if sid in seen or sid not in rows or check["source"] != rows[sid]["root"]:
                raise ValueError("Duplicate or mismatched license product/root")
            if check["exitCode"] != 0 or check["entitlement"] != "GRANTED":
                raise ValueError("Receipt does not verify granted entitlement")
            seen.add(sid)
            rows[sid].update(
                entitlement="GRANTED",
                entitlementBasis="S2 authorized account-bound live content-license check; "
                "no purchase, claim, payload download, launch or key persistence. "
                "Point-in-time access, not permanent ownership or anti-cheat clearance.",
                licenseVerification={
                    "receiptPath": str(path), "receiptSha256": expected,
                    "cliSha256": receipt["cliSha256"], "market": receipt["market"],
                    "finishedAt": check["finishedAt"], "exitCode": check["exitCode"],
                    "metadataSha256": check["metadataSha256"],
                })
    if seen != set(rows):
        raise ValueError("License receipts do not cover all nine pipeline titles")
    packet["entitlementBlocker"] = None
    packet["licenseImportPolicy"] = "Existing S2 receipts imported by pinned hash; no duplicate "
    packet["licenseImportPolicy"] += "checks performed. Account identifiers and argv remain private."
    output.write_text(json.dumps(packet, indent=2) + "\n")
    print("Imported", len(seen), "existing GRANTED checks")


if __name__ == "__main__":
    main()
