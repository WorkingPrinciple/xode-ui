#!/usr/bin/env python3
"""Read the app's account collection route; no sign-in, package or game operations."""

import argparse
import asyncio
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import uuid

from inspect_queue import DATA, load_json

HOME = Path.home()
IDENTITY = "adf8aed7203c33da9b884d3f0b6d2b9f67b10b760931ee89a35df5255d3aa604"
BINARY = HOME / "Library/Application Support/Ode to X/Service/candidates" / IDENTITY / "xodus-cli"
OUTPUT = DATA / "catalogue-ownership-v1.json"


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


async def read_collection(state):
    if hashlib.sha256(BINARY.read_bytes()).hexdigest() != IDENTITY:
        raise ValueError("Frozen CLI identity mismatch")
    argv = [str(BINARY), "manage", "--protocol", "1", "--state-dir", str(state)]
    process = await asyncio.create_subprocess_exec(
        *argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, limit=2**21)
    receipt = {"startedAt": now(), "argv": argv, "cliSha256": IDENTITY, "responses": []}
    stderr = asyncio.create_task(process.stderr.read())

    async def request(command, params):
        if command not in {"hello", "auth.status", "ode.account.read.v1"}:
            raise ValueError("Read-only command allowlist violation")
        request_id = str(uuid.uuid4())
        frame = {"kind": "request", "protocol": {"major": 1, "minor": 0},
                 "requestID": request_id, "command": command, "params": params}
        process.stdin.write((json.dumps(frame) + "\n").encode())
        await process.stdin.drain()
        while True:
            line = await asyncio.wait_for(process.stdout.readline(), timeout=130)
            if not line:
                raise RuntimeError("Management EOF before result")
            result = json.loads(line)
            if result.get("requestID") != request_id or result.get("kind") != "result":
                continue
            receipt["responses"].append({"command": command, "result": result})
            if result.get("ok") is not True:
                raise RuntimeError("Management read failed: " + str(result.get("error", {}).get("code")))
            return result["data"]

    try:
        hello = await request("hello", {"client": "S4-read-only-ownership",
                                       "clientVersion": "1.0", "requiredCapabilities": []})
        if not any(row["command"] == "ode.account.read.v1" and row["supported"]
                   for row in hello["capabilities"]):
            raise RuntimeError("Account library read capability unavailable")
        before = await request("auth.status", {})
        if before.get("state") != "credentialPresent" or not before.get("accountHash"):
            raise RuntimeError("Existing isolated account not currently bound; no login attempted")
        collection = await request("ode.account.read.v1", {
            "section": "library", "accountHash": before["accountHash"],
            "market": "US", "language": "en-US", "titleID": None})
        after = await request("auth.status", {})
        if collection.get("section") != "library" or collection.get("accountHash") != before["accountHash"] \
                or after.get("accountHash") != before["accountHash"]:
            raise RuntimeError("Account identity changed during read")
        receipt.update(collection=collection, accountBound=True, complete=True)
    except (RuntimeError, TimeoutError, ValueError, OSError) as error:
        receipt.update(complete=False, error=str(error))
    finally:
        process.stdin.close()
        try:
            await asyncio.wait_for(process.wait(), 10)
        except TimeoutError:
            process.terminate()
            await asyncio.wait_for(process.wait(), 10)
        receipt["stderr"] = (await stderr).decode(errors="replace")
        receipt["exitCode"] = process.returncode
        receipt["finishedAt"] = now()
    return receipt


def build(inputs):
    collection = inputs["collectionSummary"]
    verified = collection["complete"] and collection.get("accountBindingVerified") is True
    grants = {row["productID"]: row["acquisitionKind"] for row in collection.get("items", [])}
    if len(grants) != len(collection.get("items", [])):
        raise ValueError("Duplicate product IDs in collection summary")
    rows = []
    headroom = inputs["freeBytes"] - 157 * 2**30
    for candidate in inputs["candidates"]:
        sid = candidate["storeId"]
        kind = grants.get(sid)
        owned_filter = verified and kind is not None and kind != "subscription"
        status = "owned" if owned_filter else "unknown"
        row = {**candidate, "ownership": status, "acquisitionKind": kind,
               "source": inputs["receipt"], "ownedFilterMatch": owned_filter,
               "decisionBasis": (
                   "Present non-subscription grant: same predicate as the app Owned filter. "
                   "Unknown acquisitionKind is included by that filter but is not proof of purchase."
                   if owned_filter else
                   "No non-subscription grant for this exact product ID in the complete active "
                   "PC collection. Coordinator interpretation: the empty Owned listing "
                   "does not establish ownership or Game Pass access either way."
                   if verified else "Account collection read unavailable/incomplete/unbound."),
               "fits155Plus2GiBNow": candidate["downloadSizeBytes"] <= headroom,
               "installAuthorized": False, "launch": None}
        rows.append(row)
    queue = [row["storeId"] for row in rows
             if row["ownership"] == "owned" and row["fits155Plus2GiBNow"]]
    return {"schemaVersion": 1, "collectedAt": inputs["collectedAt"], "collectionInputs": inputs,
            "sourcePolicy": "Same app PCGamesController unified library read and "
            "LibraryPresentation Owned predicate; not public catalogue, installed roots "
            "or install-status. Exact account binding verified before/after; raw account "
            "hash and unrelated library retained only in local receipt.",
            "readOnly": True, "loginAttempts": 0, "installs": 0, "gameLaunches": 0,
            "collectionCaveat": "The provider returned a complete empty active-game "
            "collection. No Owned-filter grant was observed; ownership remains unknown. "
            "Game Pass/subscription entitlements may not appear as owned products. "
            "Do not infer purchase rights, denial of Game Pass access or install "
            "authorization from this empty read.",
            "items": rows, "approvalRequiredInstallQueue": queue,
            "queuePolicy": "Single-title disk fit against observed free bytes minus155+2GiB; "
            "not additive batch admission. Recheck immediately before any approved batch. "
            "Per-batch20GiB cap remains; anti-cheat/offline unknowns unchanged. "
            "No install authorized; coordinator approval required per batch."}


def publish(receipt, local_receipt):
    collection = receipt.get("collection", {})
    payload = collection.get("payload", {})
    complete = receipt.get("complete") is True and receipt.get("accountBound") is True \
        and isinstance(payload.get("items"), list)
    if complete:
        items = payload["items"]
        if any(not isinstance(row.get("productID"), str) or row.get("acquisitionKind") not in
               {"purchased", "subscription", "unknown"} for row in items):
            raise ValueError("Invalid collection payload")
    ranked = load_json(DATA / "s3-preflight-catalogue-v1.json")
    candidates = [{key: row[key] for key in ("storeId", "title", "downloadSizeBytes")}
                  for row in ranked["blockedItems"]]
    ids = {row["storeId"] for row in candidates}
    volume = os.statvfs(HOME / "Games/Xodus")
    inputs = {"collectedAt": now(), "freeBytes": volume.f_bavail * volume.f_frsize,
              "receipt": {"path": str(local_receipt),
                          "sha256": hashlib.sha256(local_receipt.read_bytes()).hexdigest(),
                          "command": "ode.account.read.v1", "section": "library",
                          "endpoint": "https://collections.mp.microsoft.com/v7.0/collections/query"},
              "collectionSummary": {"complete": complete, "checkedAt": collection.get("checkedAt"),
                                    "totalProductCount": len(payload.get("items", [])),
                                    "accountBindingVerified": receipt.get("accountBound") is True,
                                    "error": receipt.get("error"),
                                    "items": [row for row in payload.get("items", [])
                                              if row["productID"] in ids]},
              "candidates": candidates,
              "appSource": [{
                  "path": str(Path(__file__).resolve().parents[2] / rel),
                  "sha256": hashlib.sha256(
                      (Path(__file__).resolve().parents[2] / rel).read_bytes()).hexdigest(),
              } for rel in ("Sources/XodusPreview/PCGamesController.swift",
                            "Sources/XodusPreview/LibraryPresentation.swift")],
              "cataloguePacket": {
                  "path": str(DATA / "s3-preflight-catalogue-v1.json"),
                  "sha256": hashlib.sha256(
                      (DATA / "s3-preflight-catalogue-v1.json").read_bytes()).hexdigest()}}
    packet = build(inputs)
    OUTPUT.write_text(json.dumps(packet, indent=2, ensure_ascii=True) + "\n")
    lines = ["# Ranked-eight ownership evidence", "",
             f"Checked: {inputs['collectionSummary']['checkedAt']}; "
             f"free space: {inputs['freeBytes'] / 2**30:.2f} GiB.", "",
             "**Source:** frozen adf8 management `auth.status` -> "
             "`ode.account.read.v1(section=library)` -> `auth.status`, same "
             "account-bound Microsoft Collections v7 listing and non-subscription "
             "predicate used by the app's Owned filter. No login, purchase, "
             "package license/install or game operation.", "",
             f"Read complete: **{complete}**; active product IDs returned: "
             f"**{inputs['collectionSummary']['totalProductCount']}**. "
             + packet["collectionCaveat"], "",
             "| Rank | Title | Owned-filter result | Grant | Single-title disk fit |",
             "|---|---|---|---|---|"]
    for rank, row in enumerate(packet["items"], 1):
        lines.append(f"| {rank} | {row['title']} | {row['ownership']} | "
                     f"{row['acquisitionKind'] or 'none returned'} | "
                     f"{'yes' if row['fits155Plus2GiBNow'] else 'no'} |")
    lines.extend(["", "**Approval-required install queue: "
                  + (", ".join(packet["approvalRequiredInstallQueue"]) or "empty") + ".** "
                  "Eligibility uses exact Owned-filter grants and the current "
                  "155+2 GiB rule; no new installation authorized. "
                  "Any nonempty queue still needs coordinator approval per batch. "
                  "Anti-cheat/offline classification remains unknown.", "",
                  "The hash-bound raw collection receipt stays local; "
                  "`catalogue-ownership-v1.json` publishes only these eight results, "
                  "collection completeness/count and source identity, without account identifiers."])
    (DATA / "catalogue-ownership-v1.md").write_text("\n".join(lines) + "\n")
    print("Complete:", complete, "Error:", receipt.get("error"))
    print([(row["title"], row["ownership"], row["acquisitionKind"],
            row["fits155Plus2GiBNow"]) for row in packet["items"]])


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local-receipt", type=Path, required=True)
    parser.add_argument("--from-receipt", action="store_true",
                        help="Re-render a saved receipt without another account read")
    args = parser.parse_args()
    if args.from_receipt:
        publish(load_json(args.local_receipt), args.local_receipt)
        return
    if args.local_receipt.exists():
        raise ValueError("Do not overwrite a historical account receipt")
    state = HOME / "Library/Application Support/XodusCLI/proofs" / (
        "s4-ownership-read-" + uuid.uuid4().hex)
    receipt = await read_collection(state)
    args.local_receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    publish(receipt, args.local_receipt)


if __name__ == "__main__":
    asyncio.run(main())
