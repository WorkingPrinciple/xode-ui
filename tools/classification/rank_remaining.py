#!/usr/bin/env python3
"""Rank the bounded remaining qualification pool, without installing or launching."""

import datetime as dt
import hashlib
import json
from pathlib import Path

from build_catalogue_batch import installed_inventory
from inspect_queue import DATA

OUTPUT = DATA / "remaining-candidates-ranked-v1.json"
ORDER = [
    "9P9VNSQK1W3K", "9MWR1NC6VQ6L", "9PBWWQGXVMKC", "9PD5BM2Z8C4L",
    "9NLRT31Z4RWM", "9N8C07SS8C9D", "9NGH1FK0RJGL", "9P1Z43KRNQD4",
    "9MXND4PQLK3W", "9NV3L234VGXD", "9P861V1542BL", "9NQVHHW88XW9",
    "9P2J5D12GJL5", "9P3T7HVKM6D0", "9PJPCB188SVG", "9NFB47H2SDRX",
    "9NCJWHHMVHR0", "9P5Z4530318L", "9NXWSWBM4H6T", "9P1N07XDL1D4",
    "9P03JGQ4S1GC", "C3KLDKZBHNCZ", "9P8NSTDMZ11P", "9PNG83MDD6SH",
    "9N5PKH0KW2L1", "C17GQF31D617", "9N3LGKGF3CC2", "9PFRTPRQ569Q",
    "9NRH78B682L8", "9N116V0599HB", "9P8XKV2D5DZ5", "9NTRS771L8HL",
    "9NBL0XKVCN5L", "9NZQPT0MWTD0", "9MWBFDRGH1SW", "9PMR3T9NSF8W",
    "9NBLGGH1Z149", "9MSVVM5NS9L6", "9PLH7R84GJWP", "9NGLST31DG26",
    "9PK087LNGJC5", "9NJCVGS6T30K", "9NF6XPSBTTGB", "9N4W31HSMVVD",
    "9PPBNCXP0096", "9N94NCGM1Q2N", "9PMN4DGRT1LN",
]
REASONS = {
    "9P9VNSQK1W3K": "All title gates already observed; promotion/admission only, not another game run.",
    "9MWR1NC6VQ6L": "Queued; tooling cancellation did not consume an attempt. Small existing payload.",
    "9PBWWQGXVMKC": "Untested installed compact single-player candidate; no new download.",
    "9PD5BM2Z8C4L": "Untested installed compact candidate; progression/ordinary exit still unproved.",
    "9N8C07SS8C9D": "Untested installed compact candidate; first-save and renderer need exact card.",
    "9NLRT31Z4RWM": "Installed; app Play is not gameplay proof, full gates outstanding.",
    "9NGH1FK0RJGL": "Installed single-player candidate; exact save route outstanding.",
    "9P1Z43KRNQD4": "Installed; exact Kex candidate prepared, renderer still needs real title proof.",
    "9MXND4PQLK3W": "Very small installed Kex title; renderer/title qualification outstanding.",
    "9NV3L234VGXD": "Installed and queued; exact checkpoint/normal-quit test outstanding.",
}


def build():
    sources = []

    def source(name):
        path = DATA / name
        raw = path.read_bytes()
        sources.append({"path": str(path), "sha256": hashlib.sha256(raw).hexdigest()})
        return json.loads(raw)

    tracker = source("path-to-20-v1.json")
    v4 = source("s3-ready-packets-v4.json")
    v5 = source("s3-ready-packets-v5.json")
    catalogue = source("s3-preflight-catalogue-v1.json")
    free = source("free-morning-candidates-v1.json")
    rows = {row["storeId"]: dict(row) for row in v4["items"] + v5["items"]}
    rows.update({row["storeId"]: row for row in catalogue["blockedItems"]})
    free_rows = {row["storeId"]: row for row in free["candidates"]}
    remaining = {row["storeId"]: row for row in tracker["items"] if not row["strictWorking"]}
    inventory = installed_inventory()
    installed = {sid: item for item in inventory for sid in item["storeIds"]}
    if set(ORDER) != set(remaining) | set(free_rows) or len(ORDER) != len(set(ORDER)):
        raise ValueError("Ranking must cover every remaining tracked/free candidate exactly once")
    items = []
    for sid in ORDER:
        row = rows.get(sid, {})
        candidate = remaining.get(sid, free_rows.get(sid))
        is_free = sid in free_rows
        if is_free:
            row = free_rows[sid]
            size = max(p["MaxDownloadSizeInBytes"] for p in row["packages"]
                       if p["PackageFormat"] == "MSIXVC")
            budget = row["planningBudgetBytes"]
            route = row["routeHypothesis"]
        else:
            size = row.get("downloadSizeBytes")
            budget = size
            profile = row.get("s1Profile") or row.get("profileProposal") or {}
            name = profile.get("name") or ""
            route = ("CrossOver candidate" if "winecx" in name else
                     "Apple4 candidate" if name else "Unresolved; S1 route required")
            if sid in {"9P1Z43KRNQD4", "9MXND4PQLK3W"}:
                route = "Apple4 D3D11 Kex hypothesis; exact S1 renderer card required"
            if sid in {"9PBWWQGXVMKC", "9PD5BM2Z8C4L", "9NLRT31Z4RWM"}:
                route = "Free Wine proposed by S1; prior Apple4 candidate, new route/card unqualified"
            if sid == "9P861V1542BL":
                route = "Apple4 DX12 hypothesis; S1 Unreal-family card, exact save backend unknown"
        present = sid in installed
        partial = present and any(Path(installed[sid]["root"]).glob("*.streaming-tmp"))
        state = ("downloading; coordinator/S1 report, install-status handoff pending"
                 if sid == "9P861V1542BL" else
                 "partial streaming payload" if partial else
                 "manifest present; prior installed inventory, not fresh install-status"
                 if present else "not installed in current manifest inventory")
        incremental = 0 if present and not partial and sid != "9P861V1542BL" else budget
        blocker = candidate.get("blocker", "User must claim exact free offer; license and install unconfirmed.")
        if sid == "9P861V1542BL":
            blocker = "Download active; S2 complete install-status required before full-test admission."
        items.append({
            "rank": len(items) + 1, "storeId": sid, "title": candidate["title"],
            "verdict": candidate.get("verdict", "UNTESTED"), "installState": state,
            "downloadSizeBytes": size, "planningBudgetBytes": budget,
            "incrementalDownloadBudgetBytes": incremental,
            "fitsGross23GiBMargin": incremental is not None and incremental <= 23 * 2**30,
            "diskAdmission": "NOT ADMITTED: Valor remaining bytes/prefix/transient reserve unknown; "
            "23 GiB is gross, not available concurrent download budget.",
            "expectedRoute": route, "routeQualification": "Candidate/hypothesis, not observed title support.",
            "blocker": blocker,
            "needsUserClaim": is_free,
            "needsLicenseCheck": not present,
            "needsDownload": not present or partial or sid == "9P861V1542BL",
            "rankingBasis": REASONS.get(sid, "Installed candidates before new downloads; "
                                      "holds, large downloads and unclear routes ranked later."),
            "inventoryEvidence": installed.get(sid),
        })
    return {
        "schemaVersion": 1, "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "scope": "All remaining titles in 50-title tracker plus five researched free offers; "
        "not an exhaustive global Store/owned catalog. No extra owned titles established.",
        "rankingPolicy": "Readiness and avoided download first, then compact payload/route evidence; "
        "not numerical success probability, permission or replacement for owner queues.",
        "strictWorking": tracker["strictWorkingCount"], "needed": 20 - tracker["strictWorkingCount"],
        "disk": {"coordinatorReportedFreeGiB": 133, "prelaunchGiB": 110,
                 "stagingGiB": 110, "abortBelowGiB": 105, "grossMarginGiB": 23,
                 "valorMortisTotalDownloadGiB": 42646802432 / 2**30,
                 "valorMortisRemainingBytes": None,
                 "warning": "Do not subtract full Valor download again from current free; "
                 "do not assume it is fully allocated either. Need live S2 remaining/peak budget."},
        "sources": sources, "items": items,
        "ownerUpdate": "S1 selects Monster Sanctuary, Vampire Survivors and TUNIC for next "
        "free-Wine cards, using observed UnityPlayer/Data layout; no title support inferred.",
    }


def main():
    packet = build()
    OUTPUT.write_text(json.dumps(packet, indent=2) + "\n")
    lines = ["# Remaining candidates ranked", "", packet["scope"], "", packet["rankingPolicy"], "",
             "**Disk:** coordinator reports 133 GiB free; 110 prelaunch/staging, 105 abort. "
             "23 GiB gross margin; active Valor Mortis remaining/peak allocation UNKNOWN. "
             "No new concurrent download admitted. Sizes are catalog download/planning proxies, "
             "not installed footprints. Existing payloads still need prefix/transient space.", "",
             "| Rank | Title / ID | State | Catalog GiB | Route proposal | Claim / download | Blocker |",
             "|---|---|---|---|---|---|---|"]
    for row in packet["items"]:
        size = f"{row['downloadSizeBytes'] / 2**30:.3f}" if row["downloadSizeBytes"] else "unknown"
        lines.append(f"| {row['rank']} | {row['title']} / `{row['storeId']}` | "
                     f"{row['installState']} | {size} | {row['expectedRoute']} | "
                     f"{row['needsUserClaim']} / {row['needsDownload']} | "
                     f"{row['blocker'].replace('|', '/')} |")
    OUTPUT.with_suffix(".md").write_text("\n".join(lines) + "\n")
    print("Ranked", len(packet["items"]), "remaining candidates")


if __name__ == "__main__":
    main()
