#!/usr/bin/env python3
"""Build a morning decision list from public offers and metadata-only space samples."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess

from inspect_queue import DATA, load_json

HOME = Path.home()
FILES = HOME / ".copilot/session-state/1ead0b79-e01f-4145-93fa-61ca9b0c63da/files"
PREFIXES = HOME / "Library/Application Support/XodusCLI/prefixes"
OUTPUT = DATA / "free-morning-candidates-v1.json"
CHOICES = [
    ("9NBL0XKVCN5L", "Unreal Engine 4", "DX11 minimum; DX12 recommended", 1180660, 25,
     "Apple4 d3dmetal/default COM first hypothesis; CrossOver nativejson alternative, "
     "STA only after exact title-specific evidence",
     "Best narrative/singleplayer shape. Free base/chapter-one scope only; do not "
     "claim chapters2/3 owned or licensed. Needs user acceptance of chapter scope, "
     "free acquisition, anti-cheat evidence and new S1 exact recipe."),
    ("9NBLGGH1Z149", "Slayer", "DX11", 577940, 48,
     "Apple4 d3dmetal/default COM or CrossOver nativejson; no evidence for STA",
     "Free base; exact free roster/mode restrictions need confirmation. Good API match, "
     "very poor disk fit; login/mode/retention/anti-cheat unverified."),
    ("9NZQPT0MWTD0", "Jet Engine", "DX12", 1815780, 10,
     "Apple4 d3dmetal/default COM hypothesis; no title-specific STA evidence",
     "Smallest catalog MSIXVC payload among these racers. Online/account and "
     "anti-cheat unknowns make it worse than a simple offline title."),
    ("9MWBFDRGH1SW", "Bigworld / DAVA Engine (PCGamingWiki)", "DX11", 444200, 8,
     "Apple4 d3dmetal or CrossOver nativejson hypothesis; no STA evidence",
     "Online multiplayer/server progression; not a quick local-save retention analogue. "
     "Anti-cheat unknown; exact installed renderer not observed."),
    ("9PMR3T9NSF8W", "Jet Engine", "DX12", 1537830, 40,
     "Apple4 d3dmetal/default COM hypothesis; no STA evidence",
     "Online/server-side progress; Local Freeplay exception does not establish a "
     "local save provider. Higher disk budget; anti-cheat unknown."),
]
ENGINE_URLS = {
    "9NBL0XKVCN5L": "https://www.pcgamingwiki.com/wiki/Tell_Me_Why",
    "9NBLGGH1Z149": "https://www.pcgamingwiki.com/wiki/Killer_Instinct",
    "9NZQPT0MWTD0": "https://www.pcgamingwiki.com/wiki/Asphalt_Legends",
    "9MWBFDRGH1SW": "https://www.pcgamingwiki.com/wiki/World_of_Tanks_Blitz",
    "9PMR3T9NSF8W": "https://www.pcgamingwiki.com/wiki/Disney_Speedstorm",
}
EXCLUDED = {
    "9PCDNBHR11MR": ("Phantom Dust", "EAppx, not MSIXVC; no current 0.1 route"),
    "9P4VFFC16C43": ("One Leaves", "Appx/EAppx, not MSIXVC; no current 0.1 route"),
    "9NCJG5RVRR1C": ("OpenTTD (official)", "AppxBundle/MsixBundle, not MSIXVC. "
                     "Win32 desktop app may be repackaged; native macOS is separate scope."),
    "9WZDNCRDV0L0": ("Beach Buggy Racing", "AppxBundle, not MSIXVC"),
    "9WZDNCRDCWK8": ("Hill Climb Racing", "x86 AppxBundle, not MSIXVC"),
    "9WZDNCRFHWD2": ("Microsoft Solitaire Collection", "MsixBundle, not MSIXVC"),
    "9WZDNCRFHWCN": ("Microsoft Minesweeper", "MsixBundle, not MSIXVC"),
    "9WZDNCRFHWCP": ("Microsoft Mahjong", "MsixBundle, not MSIXVC"),
    "9WZDNCRFJ9X2": ("Microsoft Jigsaw", "x86 MsixBundle, not MSIXVC"),
    "9MW0Z4MPCS8C": ("Warzone 2100", "MsixBundle, not MSIXVC; native version separate scope"),
    "9PMF91N3LZ3M": ("Roblox - Windows", "Hyperion/Byfron Wine blocker reported; reject "
                     "as anti-cheat candidate, no bypass or alternative-client plan"),
    "9MXMZ39GVHPG": ("Brawlhalla", "10 MiB catalog stub is NOT full game size; "
                     "anti-cheat/online risk, no full payload budget or cleared recipe"),
}
PARKED = [
    ("s2-balatro-apple4-exit-v1", "Balatro parked"),
    ("s3-balatro-free-v1", "Balatro parked alternative"),
    ("s3-hogwarts-cross-26-3", "Superseded CrossOver lane; working STA Apple4 held"),
    ("s3-digging-cross-26-3", "Parked CrossOver lane; proposed STA comparison must be checked"),
    ("s3-well-cross-26-3", "Old CrossOver lane; diagnostic/provider evidence hold"),
    ("s3-well-dxmt", "Old DXMT lane; confirm not needed for candidate retest"),
    ("s2-small-9P8NSTDMZ11P-creation-dx11-d3dmetal-passive-v1", "S2 failed Inscryption; cleanup receipt says already removed"),
    ("s2-inscryption-timing300-creation-dx11-fresh-v1", "S2 timing retry result binds this exact prefix"),
]


def reference(path):
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def free_pc_offer(offer, instant):
    price = offer.get("OrderManagementData", {}).get("Price", {})
    conditions = offer.get("Conditions", {})
    platforms = conditions.get("ClientConditions", {}).get("AllowedPlatforms", [])
    return ("Purchase" in offer.get("Actions", []) and price.get("ListPrice") == 0
            and price.get("IsPIRequired") is False and price.get("CurrencyCode") == "USD"
            and any(row.get("PlatformName") == "Windows.Desktop" for row in platforms)
            and dt.datetime.fromisoformat(conditions["StartDate"]) <= instant
            < dt.datetime.fromisoformat(conditions["EndDate"]))


def collect():
    instant = dt.datetime.now(dt.timezone.utc)
    products, sources = {}, []
    for name in ("free-public-catalogue-v1.json", "free-public-catalogue-v2.json",
                 "free-public-catalogue-v3.json"):
        path = FILES / name
        sources.append(reference(path))
        for record in load_json(path)["products"]:
            for product in record["response"].get("Products", []):
                products[product["ProductId"]] = product
    wanted = {row[0] for row in CHOICES} | set(EXCLUDED)
    rows = []
    for sid in sorted(wanted):
        product = products[sid]
        packages, offers = [], []
        for availability in product["DisplaySkuAvailabilities"]:
            sku = availability["Sku"]
            for package in sku.get("Properties", {}).get("Packages", []):
                item = {key: package.get(key) for key in (
                    "PackageFormat", "MaxDownloadSizeInBytes", "Architectures", "PackageFullName")}
                if item not in packages:
                    packages.append(item)
            for offer in availability.get("Availabilities", []):
                price = offer.get("OrderManagementData", {}).get("Price", {})
                if free_pc_offer(offer, instant):
                    offers.append({"skuId": sku["SkuId"], "availabilityId": offer["AvailabilityId"],
                                   "price": price, "conditions": offer.get("Conditions"),
                                   "actions": offer["Actions"]})
        rows.append({"storeId": sid, "title": product["LocalizedProperties"][0]["ProductTitle"],
                     "packages": packages, "zeroPricePurchaseOffers": offers,
                     "source": "https://displaycatalog.mp.microsoft.com/v7.0/products?"
                     f"bigIds={sid}&market=US&languages=en-US"})
    volume = os.statvfs(PREFIXES)
    measurements = []
    for name, reason in PARKED:
        path = PREFIXES / name
        exists = path.exists()
        size = None
        if exists:
            result = subprocess.run(["/usr/bin/du", "-sk", str(path)], capture_output=True,
                                    text=True, check=True)
            size = int(result.stdout.split()[0]) * 1024
        measurements.append({"path": str(path), "kind": "whole parked prefix", "reason": reason,
                             "exists": exists, "allocatedBytes": size,
                             "deleteAuthorized": False})
        if exists:
            for rel in ("drive_c/users/crossover/AppData/Local/Temp",
                        "drive_c/users/crossover/AppData/Local/Microsoft/Windows/INetCache"):
                cache = path / rel
                if cache.is_dir() and not cache.is_symlink():
                    result = subprocess.run(["/usr/bin/du", "-sk", str(cache)],
                                            capture_output=True, text=True, check=True)
                    measurements.append({"path": str(cache), "kind": "nested cache",
                                         "parent": str(path), "exists": True,
                                         "allocatedBytes": int(result.stdout.split()[0]) * 1024,
                                         "deleteAuthorized": False})
    owned_path = FILES / "free-owned-library-read-v1.json"
    owned = load_json(owned_path)
    count = len(owned.get("collection", {}).get("payload", {}).get("items", []))
    if not owned.get("complete") or not owned.get("accountBound") or count != 0:
        raise ValueError("Owned listing changed/incomplete; review grants explicitly before publishing")
    cleanup_path = HOME / "Library/Application Support/XodusCLI/proofs/passive-small-eight-v1/9P8NSTDMZ11P/failed-prefix-cleanup.json"
    cleanup = load_json(cleanup_path)
    matrix_path = HOME / ".copilot/session-state/24963110-1b48-4e35-bae1-a54927543f42/files/s3-tried-games.json"
    matrix = load_json(matrix_path)
    return {"collectedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "sources": sources,
            "matrix": {**reference(matrix_path), "productIds": [
                row["productId"] for row in matrix["games"]]},
            "products": rows, "freeBytes": volume.f_bavail * volume.f_frsize,
            "parkedSpace": measurements, "ownedLibrary": {
                **reference(owned_path), "complete": True, "accountBound": True, "productCount": count,
                "finishedAt": owned["finishedAt"], "additionalOwnedTitlesProved": [],
                "caveat": "Complete empty Collections v7 listing, not proof of no Game Pass "
                "rights or no purchases; no login/acquisition attempted."},
            "technicalRequirements": reference(FILES / "free-tech-requirements-v1.json"),
            "inscryptionPriorCleanup": {**reference(cleanup_path),
                                        "exactPrefix": cleanup["exactPrefix"],
                                        "completed": cleanup["completed"],
                                        "prefixAbsent": cleanup["prefixAbsent"],
                                        "historicalReclaimedBytes": cleanup["observedReclaimedBytes"],
                                        "newReclaimBytes": 0,
                                        "additionalKnownApple4Paths": [],
                                        "sourceNote": "S2 direct report 2026-10-22: no additional "
                                        "known Apple4 path. Retain both S3 CrossOver lanes and proofs."}}


def build(inputs):
    indexed = {row["storeId"]: row for row in inputs["products"]}
    candidates = []
    for rank, (sid, engine, api, steam, storage_gb, route, caution) in enumerate(CHOICES, 1):
        row = indexed[sid]
        if sid in inputs["matrix"]["productIds"]:
            raise ValueError(f"Candidate {sid} already in tried-games matrix; reconcile new scope")
        if not row["zeroPricePurchaseOffers"]:
            raise ValueError(f"No explicit free acquisition offer for {sid}")
        package_bytes = max(package["MaxDownloadSizeInBytes"] for package in row["packages"]
                            if package["PackageFormat"] == "MSIXVC")
        budget = max(package_bytes, storage_gb * 10**9)
        candidates.append({**row, "rank": rank, "engine": engine, "graphicsApi": api,
                           "engineEvidence": {"source": ENGINE_URLS[sid], "checkedAt": "2026-10-22",
                                              "basis": "Public PCGamingWiki engine identification, "
                                              "not exact installed-build inspection"},
                           "apiEvidence": {"source": f"https://store.steampowered.com/api/appdetails?appids={steam}&l=english&cc=us",
                                           "checkedAt": "2026-10-22", "basis": "Publisher-submitted "
                                           "PC requirements, cross-store reference, not active renderer"},
                           "catalogPayloadBytes": package_bytes,
                           "publisherStorageBytesCrossBuild": storage_gb * 10**9,
                           "planningBudgetBytes": budget, "actualInstalledBytes": None,
                           "minimumFreeBeforeBudgetBytes": 157 * 2**30 + budget,
                           "reclaimNeededBytes": max(0, 157 * 2**30 + budget - inputs["freeBytes"]),
                           "fitsCurrent155Plus2Floor": budget <= inputs["freeBytes"] - 157 * 2**30,
                           "routeHypothesis": route, "caution": caution, "antiCheat": "unknown",
                           "supported01": None, "acquisitionAuthorized": False,
                           "installAuthorized": False, "qualified": False})
    prefix_total = sum(row["allocatedBytes"] or 0 for row in inputs["parkedSpace"]
                       if row["kind"] == "whole parked prefix")
    return {"schemaVersion": 1, "collectionInputs": inputs, "collectedAt": inputs["collectedAt"],
            "decision": "MORNING USER DECISION ONLY. Free licenses are acquisitions; "
            "no acquisition or install tonight. Ranked by technical/test fit, not predicted "
            "success or popularity score. No title has an approved exact recipe or anti-cheat clearance.",
            "diskRule": "155 GiB retained floor plus 2 GiB safety margin = 157 GiB retained. "
            "Planning budget=max(current PC MSIXVC MaxDownloadSizeInBytes, publisher cross-build "
            "storage requirement); NOT measured installed size/peak. Additional staging, prefix, "
            "shader and network downloads unknown; required free/reclaim values are lower bounds.",
            "candidates": candidates,
            "excluded": [{**indexed[sid], "exclusion": reason} for sid, (_, reason) in EXCLUDED.items()],
            "parkedPrefixAllocatedTotalBytes": prefix_total,
            "freeAfterAllConditionalPrefixReclaimBytes": inputs["freeBytes"] + prefix_total,
            "reclaimPolicy": "Proposal only. Whole-prefix rows and nested caches overlap; "
            "sum only whole prefixes once. du allocated bytes do not guarantee APFS physical "
            "reclaim (clones/snapshots/shared extents). Saves, registries, receipts and prefix "
            "history may be valuable; inspect/preserve under owner+user decision before deletion. "
            "Documents links target host Documents; never follow/delete host targets. "
            "Quiescence/references not exhaustively checked; no deletion authorized. "
            "Working/pending retained prefixes, payloads and proof directories excluded.",
            "accountLibrary": inputs["ownedLibrary"],
            "acquisitions": 0, "installs": 0, "gameLaunches": 0, "deletions": 0}


def render(packet):
    lines = ["# Free-title morning decision list", "", packet["decision"], "",
             f"Snapshot {packet['collectedAt']}; free "
             f"**{packet['collectionInputs']['freeBytes'] / 2**30:.3f} GiB**. "
             "**No title fits the 155+2 GiB retained floor.**", "",
             packet["diskRule"], "",
             "| Rank | Title / MSIXVC product | Payload GiB | Planning GiB | Engine / public API | Route hypothesis | Min reclaim GiB |",
             "|---|---|---|---|---|---|---|"]
    for row in packet["candidates"]:
        lines.append(f"| {row['rank']} | [{row['title']}](https://www.xbox.com/en-us/games/store/-/{row['storeId']}) "
                     f"`{row['storeId']}` | {row['catalogPayloadBytes']/2**30:.3f} | "
                     f"{row['planningBudgetBytes']/2**30:.3f} | {row['engine']} / {row['graphicsApi']} | "
                     f"{row['routeHypothesis']} | {row['reclaimNeededBytes']/2**30:.3f} |")
    lines.extend(["", "## Fit and licensing cautions", ""])
    for row in packet["candidates"]:
        lines.append(f"- **{row['title']}:** {row['caution']} "
                     f"[Engine]({row['engineEvidence']['source']}); "
                     f"[PC API requirements]({row['apiEvidence']['source']}).")
    lines.extend(["", "**Anti-cheat remains unknown for every ranked title**; singleplayer "
                  "is not evidence of none. Apple4/CrossOver are renderer-family hypotheses "
                  "only; no blanket STA, inherited launch grant or WORKING claim.", "",
                  "## Account library", "", "Fresh existing-account `auth.status` -> "
                  "`ode.account.read.v1(section=library)` -> `auth.status`: complete, same "
                  "account bound, **0 product rows**, so **no already-owned additions proved**. "
                  "Empty collection is not a denial of subscription access or proof of no purchases. "
                  "Raw account identifiers stay local; receipt identity in JSON.", "",
                  "## Small/popular exclusions", "",
                  "| Title | Largest catalog payload GiB (not install size) | Reason |",
                  "|---|---|---|"])
    for row in packet["excluded"]:
        size = max((item["MaxDownloadSizeInBytes"] or 0 for item in row["packages"]), default=0)
        lines.append(f"| {row['title']} | {size/2**30:.3f} | {row['exclusion']} |")
    lines.extend(["", "Fallout Shelter was not returned as an exact title in current Desktop "
                  "search; Pinball FX/FX3 not returned as exact Desktop titles either. "
                  "Xbox console/cloud pages are not PC install evidence. They are not queued. "
                  "Search result zero prices (including unrelated paid Game Pass products) "
                  "were NOT treated as free licenses; ranked rows retain explicit zero-USD "
                  "Purchase availability records.", "",
                  "## Read-only parked-prefix/cache reclaim proposal", "", packet["reclaimPolicy"], "",
                  "| Exact path | Allocated GiB | Interpretation |", "|---|---|---|"])
    for row in packet["collectionInputs"]["parkedSpace"]:
        if row["kind"] == "nested cache":
            continue
        size = f"{row['allocatedBytes']/2**30:.6f}" if row["exists"] else "absent; 0 reclaim"
        lines.append(f"| `{row['path']}` | {size} | "
                     f"{row.get('reason', 'Nested cache; included in parent, NOT additive')} |")
    lines.extend(["", "Exact nested Temp/INetCache paths and sizes are retained in JSON; "
                  "they are already included in their parent and never additive.", "",
                  f"Conditional whole-prefix sum **{packet['parkedPrefixAllocatedTotalBytes']/2**30:.3f} GiB**; "
                  f"optimistic free afterward **{packet['freeAfterAllConditionalPrefixReclaimBytes']/2**30:.3f} GiB** "
                  "(not a guaranteed physical gain). No ranked title fits even after this sum. "
                  "Absent Inscryption names are not reclaimable; do not count prior cleanup again. "
                  "The retained `s3-inscryption-crossover-nativejson-alt-v1` lane is deliberately "
                  "excluded from parked-prefix proposals, as is the admitted fresh "
                  "`s3-inscryption-crossover-nativejson-alt-retry-v2` route. "
                  "S2 reports no additional known Apple4 cache path; earlier cleanup "
                  "already reclaimed bytes, not new morning capacity.", "",
                  "Sources, full offer/package fields, account receipt hash and technical "
                  "requirements receipt hash: `free-morning-candidates-v1.json`. "
                  "No acquisition, install, launch, prefix write or deletion performed."])
    (DATA / "free-morning-candidates-v1.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    if args.refresh:
        packet = build(collect())
        OUTPUT.write_text(json.dumps(packet, indent=2) + "\n")
        render(packet)
    else:
        packet = load_json(OUTPUT)
        if packet != build(packet["collectionInputs"]):
            raise ValueError("Morning candidate list does not reproduce")
    print("Free GiB", packet["collectionInputs"]["freeBytes"] / 2**30,
          "conditional prefix GiB", packet["parkedPrefixAllocatedTotalBytes"] / 2**30)


if __name__ == "__main__":
    main()
