#!/usr/bin/env python3
"""Catalogue-only ranking and read-only Kex package facts; never installs/launches."""

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import zipfile

from collect_wine_proxies import fetch
from expand_small_queue import collect
from build_small_packets import fast_path
from inspect_queue import DATA, SIGNATURES, STEAM_IDS, inspect_package, load_json

REDDIT = Path("/Users/dragoshont/.copilot/session-state/"
              "24963110-1b48-4e35-bae1-a54927543f42/files/reddit-popular-games.json")
OUTPUT = DATA / "s3-preflight-catalogue-v1.json"
FACTS = DATA / "doom-quake-installed-facts-v1.json"
ORDER = (
    ("C17GQF31D617", "INSIDE", "Inside"),
    ("9N3LGKGF3CC2", "Nine Sols", "Nine_Sols"),
    ("9PFRTPRQ569Q", "Blue Prince", "Blue_Prince"),
    ("9N116V0599HB", "Hollow Knight: Silksong", "Hollow_Knight:_Silksong"),
    ("9N5PKH0KW2L1", "Minishoot' Adventures", "Minishoot_Adventures"),
    ("9NRH78B682L8", "SUPERHOT: MIND CONTROL DELETE", "Superhot:_Mind_Control_Delete"),
    ("9P8XKV2D5DZ5", "Dome Keeper", "Dome_Keeper"),
    ("9NTRS771L8HL", "Disco Elysium - The Final Cut", "Disco_Elysium"),
)
REASONS = (
    "Compact single-player Unity title; prefer the public DX11 path if confirmed.",
    "Single-player 2D Unity candidate; title-specific Store/runtime remains untested.",
    "Popular puzzle Unity/DX11 candidate; newer title and save-day rules need "
    "separate research before timed retention checks.",
    "Unity 2D candidate and strong Reddit demand, but public exact-Store sign-in "
    "report and larger size lower it. Hollow Knight's success is not transferable.",
    "Small single-player Unity candidate; public positive Wine proxy and review "
    "activity are independent of absent Reddit top-50 matching.",
    "Single-player Unity/DX11 candidate, exact MIND CONTROL DELETE edition only.",
    "Small Godot candidate; public GL-only API and unresolved host GL route "
    "lower it despite positive Proton; exact renderer selection still required.",
    "Popular narrative Unity candidate; larger footprint and input/save latency "
    "make it lower priority than the smaller 2D candidates.",
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def installed_inventory():
    rows = []
    for root in sorted((Path.home() / "Games/Xodus").iterdir()):
        if not root.is_dir() or root.is_symlink():
            continue
        manifests = [path for path in root.iterdir()
                     if path.name.lower() == "microsoftgame.config"]
        for manifest in manifests:
            text = manifest.read_text()
            ids = re.findall(r"<StoreId>\s*([^<]+)\s*</StoreId>", text, re.I)
            rows.append({"root": str(root), "manifest": str(manifest),
                         "manifestSha256": sha(manifest), "storeIds": ids})
    return rows


def research(candidate):
    if candidate[0] == "9NTRS771L8HL":
        # Exact PCGW Steam row and appdetails name agree; storesearch returns no hits.
        STEAM_IDS[candidate[0]] = 632470
    row = collect(candidate)
    receipt, raw = fetch(row["public"]["pcgamingwiki"]["url"])
    receipt["facts"] = [
        line for line in (raw or "").splitlines()
        if re.search(r"anti.?cheat|denuvo|battl.?eye|easy.?anti|vanguard|"
                     r"^\|.*(?:offline|drm|single.?player|online|account).*="
                     r"|^\{\{Availability/row", line, re.I)
    ][:25]
    receipt["scope"] = "Short PC/Steam DRM/network table observations, not Xbox package clearance."
    row["public"]["drmNetworkInspection"] = receipt
    return row


def build(inputs):
    catalogue = inputs["catalogueProducts"]
    by_id = {row["storeId"]: row for row in inputs["evidence"]}
    installed = {sid for row in inputs["installed"] for sid in row["storeIds"]}
    existing = set(inputs["existingPacketIds"])
    matrix = set(inputs["matrixIds"])
    items = []
    for rank, ((sid, _, _), reason) in enumerate(zip(ORDER, REASONS), 1):
        if sid in installed or sid in existing or sid in matrix:
            raise ValueError(f"{sid}: not a new uninstalled candidate")
        row = dict(by_id[sid])
        reddit = []
        for group in ("top50Mac", "top50Overall"):
            for result in inputs["reddit"][group]:
                if any(product["productId"] == sid for product in result.get("products", [])):
                    reddit.append({"list": group, "title": result["title"],
                                   "rank": result.get("rank"), "score": result.get("score"),
                                   "evidence": result.get("evidence", [])})
        product = catalogue[sid]
        tier = row["public"].get("protonDB", {}).get("summary") or {}
        single = "Single-player" in row["steam"].get("categories", [])
        row.update(
            rank=rank, rankReason=reason, numericProbability=None,
            ownership="catalogue, ownership unverified",
            packageFormat=product["packageFormat"],
            packageFormatEvidence=product["packageFormatEvidence"],
            antiCheat=product["antiCheat"],
            antiCheatEvidence=product["antiCheatEvidence"],
            supported01=product["supported01"],
            redditCrossCheck={"source": inputs["redditSource"], "matches": reddit,
                              "finding": "Matched title evidence" if reddit else
                              "No exact product match in either supplied top-50 list; "
                              "Steam review activity is the separate popularity proxy."},
            evidenceAssessment={
                "positiveProtonProxy": tier.get("tier") in {"platinum", "gold"},
                "singlePlayerSteamCategory": single,
                "requiredSteamAccount": row["steam"].get("requiredAccount"),
                "offlineXboxBuild": None,
                "noAntiCheatEstablished": product["antiCheat"].lower() == "none",
                "limitation": "Single-player/positive Proton is not offline Xbox proof "
                "or anti-cheat absence. Unknown stays unknown; no automatic support.",
                "knownStoreServiceCaveat": (
                    "PCGW exact Microsoft Store row reports black screen when "
                    "not signed in; public Steam DRM-free is not Store clearance."
                    if sid == "9N116V0599HB" else None),
            },
            readyForLaunch=False, launch=None, discovery=None,
            installStatus=None, saveLocation=None, windowTitle=None,
            save_path=None,
            saveEvidence={
                "url": row["public"]["pcgamingwiki"]["url"],
                "checkedAt": row["public"]["pcgamingwiki"]["checkedAt"],
                "facts": [line for line in row["public"]["pcgamingwiki"]["facts"]
                          if "saves|" in line],
                "limitation": "Public PC/platform rows only; no observed host path "
                "or selected Store save-provider directory.",
            },
            fastPath=fast_path(row),
            blocker="No install attempted: ownership unverified; coordinator "
            "holds all installs, current disk below 155 GiB + 2 GiB margin. "
            "No selected S1 recipe or observed runtime/save evidence.",
            preflight={"installAttempted": False, "statusCommand": None,
                       "discovery": None, "warning": "Ranking only; no copy-paste "
                       "install/launch commands and no manufactured complete status."},
        )
        items.append(row)
    return {
        "schemaVersion": 1, "collectedAt": inputs["collectedAt"],
        "cliSha256": inputs["cliSha256"],
        "primaryRuntimeSha256": inputs["primaryRuntimeSha256"],
        "s1RegistrySha256": inputs["s1RegistrySha256"],
        "gameLaunches": 0, "collectionInputs": inputs, "items": [],
        "blockedItems": items, "candidateOrder": [row[0] for row in ORDER],
        "workingTarget": 20,
        "scope": "Same installed-preflight container schema, catalogue ranking only. "
        "Eight uninstalled candidates; all in blockedItems, none execution-ready.",
        "installPolicy": {"authorizedNow": False, "ownershipUnverified": True,
                          "operationalMinimumFreeBytes": 155 * 2**30,
                          "stagingMarginBytes": 2 * 2**30,
                          "batchBudgetBytes": 20 * 2**30, "deletions": False},
        "rankedCatalogueDownloadBytes": sum(row["downloadSizeBytes"] for row in items),
        "budgetCaveat": "Ranking does not authorize installing all eight. A later "
        "batch must separately cap cumulative admitted/allocated bytes at 20 GiB "
        "and obey fresh 155+2 GiB margin. Zero size is unknown, not free.",
        "rejected": inputs["rejected"],
    }


def collect_facts():
    staging = load_json(DATA / "small-game-staging-v1.json")
    research_rows = {row["storeId"]: row for row in
                     load_json(DATA / "small-game-evidence-v1.json")["items"]}
    items = []
    for sid in ("9MXND4PQLK3W", "9P1Z43KRNQD4"):
        staged = next(row for row in staging["items"] if row["storeId"] == sid)
        package = inspect_package({"storeId": sid, "installRoot": staged["root"]},
                                  load_json(SIGNATURES)["signatures"])
        root = Path(staged["root"])
        resources = []
        for path in sorted(root.glob("*.kpf")):
            with path.open("rb") as stream:
                header = stream.read(16)
            observation = {"path": str(path), "sizeBytes": path.stat().st_size,
                           "sha256": sha(path), "headerHex": header.hex(),
                           "archiveReadableWithoutDecryption": zipfile.is_zipfile(path)}
            if observation["archiveReadableWithoutDecryption"]:
                with zipfile.ZipFile(path) as archive:
                    entries = archive.infolist()
                    observation["entryCount"] = len(entries)
                    observation["rendererNamedEntries"] = [
                        item.filename for item in entries
                        if re.search(r"(?:vulkan|d3d11|opengl|shader|renderer)", item.filename, re.I)
                    ][:25]
            resources.append(observation)
        items.append({
            "storeId": sid, "title": staged["title"], "gameDir": str(root),
            "package": package, "resources": resources,
            "topLevelNames": sorted(path.name for path in root.iterdir()),
            "lastCompleteAdf8Status": staged["installStatus"],
            "publicEngineAndApiProxy": research_rows[sid]["public"]["pcgamingwiki"],
            "installedEngineName": None, "installedEngineVersion": None,
            "activeRenderer": None, "launch": None,
            "interpretation": "Exact manifest executable and package resource names "
            "observed read-only. Opaque main executable cannot establish engine "
            "version/compiled drivers. KPF/SDL layout agrees with public Kex reference "
            "but is not an installed engine-version proof or active-renderer result. "
            "Archive listing is capability/layout only, not selected backend.",
        })
    return {"schemaVersion": 1, "collectedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "readOnly": True, "gameLaunches": 0, "decryptedFiles": 0,
            "scope": "Installed-file facts for S1 row research; no launch commands.",
            "items": items}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    if args.refresh:
        prior = load_json(OUTPUT) if OUTPUT.exists() else None
        hades = next((row for row in prior["collectionInputs"]["evidence"]
                      if row["storeId"] == "9P8DL6W0JBB8"), None) if prior else None
        if hades is None and prior:
            hades = next((row["evidence"] for row in prior.get("rejected", [])
                          if row["storeId"] == "9P8DL6W0JBB8"), None)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            evidence = list(pool.map(research, ORDER))
        base = load_json(DATA / "s3-preflight-small-v1.json")
        matrix = Path("/Users/dragoshont/.copilot/session-state/"
                      "24963110-1b48-4e35-bae1-a54927543f42/files/s3-tried-games.json")
        products = load_json(DATA / "game-compatibility-v1.json")["products"]
        volume = os.statvfs(Path.home() / "Games/Xodus")
        inputs = {
            "collectedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "evidence": evidence, "reddit": load_json(REDDIT),
            "redditSource": {"path": str(REDDIT), "sha256": sha(REDDIT)},
            "catalogueProducts": {sid: products[sid] for sid, _, _ in ORDER},
            "installed": installed_inventory(),
            "existingPacketIds": [row["storeId"] for name in
                                  ("s3-ready-packets-v4.json", "s3-ready-packets-v5.json")
                                  for row in load_json(DATA / name)["items"]],
            "matrixIds": [row["productId"] for row in load_json(matrix)["games"]],
            "matrixSource": {"path": str(matrix), "sha256": sha(matrix)},
            "freeBytes": volume.f_bavail * volume.f_frsize,
            "rejected": [{
                "storeId": "9P8DL6W0JBB8", "title": "Hades",
                "reason": "Exact Microsoft Store PCGW row reports no progress "
                "beyond title screen without Xbox Live account connection. "
                "Defer behind less service-dependent candidates; Steam DRM-free "
                "does not establish offline Xbox operation.",
                "evidence": hades,
            }],
            **{key: base[key] for key in
               ("cliSha256", "primaryRuntimeSha256", "s1RegistrySha256")},
        }
        OUTPUT.write_text(json.dumps(build(inputs), indent=2, ensure_ascii=True) + "\n")
        FACTS.write_text(json.dumps(collect_facts(), indent=2, ensure_ascii=True) + "\n")
    else:
        packet = load_json(OUTPUT)
        if build(packet["collectionInputs"]) != packet:
            raise ValueError("Frozen ranking does not reproduce")
    print("Eight catalogue-only candidates; no installs/launches; DOOM64/Quake facts recorded")


if __name__ == "__main__":
    main()
