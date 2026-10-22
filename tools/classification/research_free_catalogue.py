#!/usr/bin/env python3
"""Collect public Store search/catalog metadata only; no acquisition or install."""

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import json
from pathlib import Path
import urllib.parse

from classify_catalogue import request_json, catalog_url

QUERIES = ("Phantom Dust", "Fallout Shelter", "Pinball FX", "Killer Instinct",
           "OpenTTD", "Hill Climb Racing", "Microsoft Solitaire Collection",
           "Microsoft Minesweeper", "Microsoft Mahjong", "Microsoft Jigsaw",
           "Crossy Road", "Asphalt Legends", "Disney Speedstorm", "Roblox",
           "Battle for Wesnoth", "Island Saver", "Starlit Adventures")
MORE_QUERIES = ("World of Tanks Blitz", "Gems of War", "Stumble Guys",
                "Super Animal Royale", "Minion Rush", "Angry Birds 2",
                "Idle Champions", "Path of Exile", "Warframe", "Paladins",
                "Brawlhalla", "Hawken", "SMITE", "Trove", "Century Age of Ashes")
OFFLINE_QUERIES = ("One Leaves", "The Awesome Adventures of Captain Spirit",
                   "Life is Strange", "Life is Strange 2", "Dead or Alive 6",
                   "Dead or Alive 5 Last Round", "Pinball FX2", "Dungeon Defenders II")


def search(query):
    url = "https://storeedgefd.dsx.mp.microsoft.com/v9.0/search?" + urllib.parse.urlencode({
        "query": query, "market": "US", "locale": "en-us", "deviceFamily": "Windows.Desktop"})
    raw = request_json(url)
    rows = raw.get("Payload", {}).get("SearchResults", [])[:4]
    return {"query": query, "url": url, "results": [
        {key: row[key] for key in ("ProductId", "Title", "Price", "Rating", "RatingCount")
         if key in row} for row in rows]}


def catalog(sid):
    url = catalog_url(sid, "US")
    raw = request_json(url)
    return {"productId": sid, "url": url, "response": raw}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--more", action="store_true")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Preserve historical evidence; use a new output path")
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        searches = list(executor.map(search, OFFLINE_QUERIES if args.offline else
                                     MORE_QUERIES if args.more else QUERIES))
        ids = sorted({row["ProductId"] for query in searches for row in query["results"]})
        products = list(executor.map(catalog, ids))
    packet = {"collectedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
              "searches": searches, "products": products,
              "installs": 0, "purchases": 0, "acquisitions": 0, "gameLaunches": 0}
    args.output.write_text(json.dumps(packet, indent=2) + "\n")
    print(args.output, hashlib.sha256(args.output.read_bytes()).hexdigest())
    for query in searches:
        print(query["query"], [(row["ProductId"], row["Title"], row.get("Price"))
                               for row in query["results"]])


if __name__ == "__main__":
    main()
