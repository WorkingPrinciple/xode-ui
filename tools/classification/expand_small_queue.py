#!/usr/bin/env python3
"""Collect public small-game evidence; never install or launch."""

import concurrent.futures
import datetime as dt
import json
import re

from collect_wine_proxies import fetch, wiki_fields
from inspect_queue import DATA, catalog_sizes, positive_sizes, public_requirements


CANDIDATES = (
    ("9P9VNSQK1W3K", "Brotato", "Brotato"),
    ("9PD5BM2Z8C4L", "Vampire Survivors", "Vampire_Survivors"),
    ("9MXND4PQLK3W", "DOOM 64", "Doom_64"),
    ("9P1Z43KRNQD4", "Quake", "Quake_Enhanced"),
    ("9P46M5JQ2PTF", "DOOM + DOOM II", "Doom_%2B_Doom_II"),
    ("9NLRT31Z4RWM", "TUNIC", "Tunic"),
    ("9P8NSTDMZ11P", "Inscryption", "Inscryption"),
    ("9PBWWQGXVMKC", "Monster Sanctuary", "Monster_Sanctuary"),
    ("9MSVVM5NS9L6", "DREDGE", "Dredge"),
    ("9NX6K9HN4F4K", "Pentiment", "Pentiment"),
    ("9NMNMS626R59", "Halls of Torment", "Halls_of_Torment"),
    ("9N42CT1J5WGW", "Fallout", "Fallout"),
)


def collect(candidate):
    store_id, title, slug = candidate
    row = {"storeId": store_id, "title": title}
    catalog = catalog_sizes(row)
    steam = public_requirements(row)
    row.update(catalog=catalog, steam=steam, downloadSizeBytes=max(positive_sizes(catalog), default=0))
    row["public"] = {}
    for name, url in (
        ("pcgamingwiki", f"https://www.pcgamingwiki.com/wiki/{slug}?action=raw"),
        ("appleGamingWiki", f"https://www.applegamingwiki.com/wiki/{slug}?action=raw"),
    ):
        receipt, body = fetch(url)
        receipt["ratings"] = wiki_fields(body)
        # Short factual table rows only, not article republication.
        receipt["facts"] = [
            line for line in (body or "").splitlines()
            if re.search(r"row/engine|direct3d|opengl|vulkan|Game data/saves|xbox cloud\s*=|steam appid"
                         r"|^\|(?:mouse menu|controller support|xinput controllers)[ \t]*=", line, re.I)
        ][:45]
        receipt["bodyAvailable"] = body is not None
        row["public"][name] = receipt
    app_id = steam.get("appID") or steam.get("appId")
    if not app_id:
        app_id = re.search(r"/app/(\d+)", json.dumps(steam))
        app_id = app_id.group(1) if app_id else None
    if app_id:
        receipt, body = fetch(f"https://www.protondb.com/api/v1/reports/summaries/{app_id}.json")
        receipt["summary"] = json.loads(body) if body else None
        receipt["reportUrl"] = f"https://www.protondb.com/app/{app_id}"
        row["public"]["protonDB"] = receipt
    return row


def main():
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        items = list(pool.map(collect, CANDIDATES))
    output = {"schemaVersion": 1, "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
              "scope": "Public PC/Steam Wine proxies, not Store gameplay qualification",
              "items": items}
    (DATA / "small-game-evidence-v1.json").write_text(json.dumps(output, indent=2) + "\n")
    for row in items:
        print(row["title"], round(row["downloadSizeBytes"] / 2**30, 3),
              row["public"].get("protonDB", {}).get("summary"),
              row["public"]["appleGamingWiki"]["ratings"])


if __name__ == "__main__":
    main()
