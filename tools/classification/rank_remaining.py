#!/usr/bin/env python3
"""Rank the bounded remaining qualification pool, without installing or launching."""

import datetime as dt
import hashlib
import json
from pathlib import Path

from build_catalogue_batch import installed_inventory
from inspect_queue import DATA

OUTPUT = DATA / "remaining-candidates-ranked-v1.json"
FREE_GIB = 127
FLOOR_GIB = 110
MARGIN_GIB = FREE_GIB - FLOOR_GIB
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
    "9MWR1NC6VQ6L": "Fresh reload retained Day2 progress; observed final quit still required.",
    "9PBWWQGXVMKC": "World PASS-candidate; reload blocked by RPS sign-in infrastructure, retry pending.",
    "9PD5BM2Z8C4L": "Untested installed compact candidate; progression/ordinary exit still unproved.",
    "9N8C07SS8C9D": "Untested installed compact candidate; first-save and renderer need exact card.",
    "9NLRT31Z4RWM": "World/reload INCONCLUSIVE; stick not retained without normal quit, qualification hold.",
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
    verified = {row["storeId"]: row for row in
                source("pipeline-install-entitlement-v1.json")["items"]}
    rows = {row["storeId"]: dict(row) for row in v4["items"] + v5["items"]}
    rows.update({row["storeId"]: row for row in catalogue["blockedItems"]})
    free_rows = {row["storeId"]: row for row in free["candidates"]}
    remaining = {row["storeId"]: row for row in tracker["items"] if not row["strictWorking"]}
    inventory = installed_inventory()
    installed = {sid: item for item in inventory for sid in item["storeIds"]}
    active_order = [sid for sid in ORDER if sid in remaining or sid in free_rows]
    if set(active_order) != set(remaining) | set(free_rows) or len(ORDER) != len(set(ORDER)):
        raise ValueError("Ranking must cover every remaining tracked/free candidate exactly once")
    items = []
    for sid in active_order:
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
        state = ("passive attempted; coordinator report, fresh install-status receipt not supplied"
                 if sid == "9P861V1542BL" else
                 "partial streaming payload" if partial else
                 "manifest present; prior installed inventory, not fresh install-status"
                 if present else "not installed in current manifest inventory")
        verification = verified.get(sid)
        if verification and present and verification["root"] == installed[sid]["root"]:
            status = verification["installStatus"]
            if (verification["processExitCode"] == 0 and status["success"]
                    and status["status"] == "complete" and status["product"] == sid):
                state = "complete; fresh read-only install-status " + verification["checkedAt"]
        incremental = 0 if present and not partial else budget
        blocker = candidate.get("blocker", "User must claim exact free offer; license and install unconfirmed.")
        needs_download = not present or partial
        extension = (ORDER.index(sid) >= 10 and not needs_download and not is_free
                     and candidate.get("verdict") in {"UNTESTED", "NOT_TESTED"})
        items.append({
            "rank": ORDER.index(sid) + 1, "storeId": sid, "title": candidate["title"],
            "verdict": candidate.get("verdict", "UNTESTED"), "installState": state,
            "downloadSizeBytes": size, "planningBudgetBytes": budget,
            "incrementalDownloadBudgetBytes": incremental,
            "fitsGrossMargin": incremental is not None and incremental <= MARGIN_GIB * 2**30,
            "diskAdmission": "NOT ADMITTED: prefix/transient reserve and current free space require "
            "S2 preflight; 17 GiB is gross, not available concurrent download budget.",
            "expectedRoute": route, "routeQualification": "Candidate/hypothesis, not observed title support.",
            "blocker": blocker,
            "needsUserClaim": is_free,
            "needsLicenseCheck": not present,
            "needsDownload": needs_download,
            "pipelineExtensionCandidate": extension,
            "purchasePolicy": "No purchase or claim proposed for manifest-present payload; "
            "fresh entitlement/install-status check still required, stop on any price or grant request.",
            "rankingBasis": REASONS.get(sid, "Installed candidates before new downloads; "
                                      "holds, large downloads and unclear routes ranked later."),
            "inventoryEvidence": installed.get(sid),
            "installVerification": verification,
        })
    return {
        "schemaVersion": 1, "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "scope": "All remaining titles in 50-title tracker plus five researched free offers; "
        "not an exhaustive global Store/owned catalog. No extra owned titles established.",
        "rankingPolicy": "Readiness and avoided download first, then compact payload/route evidence; "
        "not numerical success probability, permission or replacement for owner queues.",
        "strictWorking": tracker["strictWorkingCount"], "needed": 20 - tracker["strictWorkingCount"],
        "disk": {"coordinatorReportedFreeGiB": FREE_GIB, "prelaunchGiB": FLOOR_GIB,
                 "stagingGiB": FLOOR_GIB, "abortBelowGiB": 105, "grossMarginGiB": MARGIN_GIB,
                 "reportedAt": "2026-10-22T19:51:42.038+00:00",
                 "sourceSession": "24963110-1b48-4e35-bae1-a54927543f42",
                 "valorMortisTotalDownloadGiB": 42646802432 / 2**30,
                 "valorMortisRemainingBytes": None,
                 "warning": "Existing payload size is not incremental allocation. Prefix/transient "
                 "growth unknown; need live S2 preflight, no further download admitted."},
        "pipelineExtension": {
            "storeIds": [row["storeId"] for row in items if row["pipelineExtensionCandidate"]],
            "scope": "Ranks after top ten, manifest present, no streaming marker, no new claim or "
            "download, untested only. Existing queue overlap is not additional unique capacity.",
            "diskBasis": "Zero incremental payload download fits reported 17 GiB gross headroom; "
            "not proof that unknown prefix/transient growth fits. Admission remains conditional.",
        },
        "sources": sources, "items": items,
        "ownerUpdate": "Monster admitted WORKING by coordinator22:57; TUNIC inconclusive, Stardew retention YES/quit "
        "unobserved, Valor prefix VC++ prerequisite missing; strict count unchanged.",
    }


def main():
    packet = build()
    OUTPUT.write_text(json.dumps(packet, indent=2) + "\n")
    lines = ["# Remaining candidates ranked", "", packet["scope"], "", packet["rankingPolicy"], "",
             "**Disk:** coordinator reports 127 GiB free; 110 prelaunch/staging, 105 abort. "
             "17 GiB gross margin; prefix/transient allocation UNKNOWN. "
             "No new concurrent download admitted. Sizes are catalog download/planning proxies, "
             "not installed footprints. Existing payloads still need prefix/transient space.", "",
             "**Pipeline extension (conditional, not launch grants):** "
             + ", ".join(row["title"] for row in packet["items"] if row["pipelineExtensionCandidate"])
             + ". Zero new payload download; entitlement, prefix budget, route/card and owner admission "
             "still required. No added unique-capacity claim for already queued titles.", "",
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
