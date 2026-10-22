#!/usr/bin/env python3
"""Read public compatibility databases; never inspect accounts or launch games."""

from __future__ import annotations

import concurrent.futures
import argparse
import datetime as dt
import hashlib
import json
import re
import urllib.error
import urllib.parse
import urllib.request

from inspect_queue import DATA, load_json


SLUGS = [
    "Hogwarts_Legacy", "No_Man%27s_Sky", "A_Game_About_Digging_a_Hole",
    "Well_Dweller", "Balatro", "Limbo", "Stardew_Valley", "Replaced", "Mixtape",
    "Subnautica_2", "The_Elder_Scrolls_IV:_Oblivion", "Minecraft",
    "Kingdom_Come:_Deliverance", "The_Elder_Scrolls_V:_Skyrim_Special_Edition",
    "Fallout_4", "Final_Fantasy_IV", "Wasteland_Remastered", "Dishonored",
    "Forever_Ago", "Deathloop", "Beast_of_Reincarnation", "Keeper",
    "Bluey%27s_Happy_Snaps", "Valor_Mortis", "South_of_Midnight",
    "Age_of_Empires_IV", "Resonance:_A_Plague_Tale_Legacy", "High_On_Life_2",
    "Kingdom_Come:_Deliverance_II", "Fable_(2026)",
]
METHODS = (
    "crossover", "game porting toolkit", "gptk", "whisky", "wine",
    "rosetta 2", "native",
)
TIER_VALUES = {"platinum", "gold", "silver", "bronze", "borked", "pending"}
CW_SLUGS = {
    "9N8C07SS8C9D": "final-fantasy-iv-1",
}


def fetch(url):
    receipt = {
        "url": url, "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "httpStatus": None, "sha256": None, "error": None,
    }
    request = urllib.request.Request(url, headers={"User-Agent": "OdeToX-public-compatibility-research/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read(2_000_001)
            receipt["httpStatus"] = response.status
            receipt["resolvedUrl"] = response.url
    except urllib.error.HTTPError as error:
        receipt["httpStatus"] = error.code
        receipt["error"] = str(error)
        return receipt, None
    except (urllib.error.URLError, TimeoutError) as error:
        receipt["error"] = str(error)
        return receipt, None
    if len(raw) > 2_000_000:
        receipt["error"] = "Response exceeds bounded collection size"
        return receipt, None
    receipt["sha256"] = hashlib.sha256(raw).hexdigest()
    return receipt, raw.decode("utf-8")


def wiki_fields(text):
    fields = {}
    if text is None or "{{Compatibility/macOS" not in text:
        return fields
    for match in re.finditer(r"^\|[ \t]*([^=\n]+?)[ \t]*=[ \t]*(.*)$", text, re.M):
        key, value = match.groups()
        key = key.strip().lower()
        if key in METHODS:
            fields[key] = value.strip() or None
    return fields


def collect(row, slug, previous=None):
    store_id = row["storeId"]
    apple_url = f"https://www.applegamingwiki.com/wiki/{slug}?action=raw"
    apple, apple_raw = fetch(apple_url)
    apple["ratings"] = wiki_fields(apple_raw)
    apple["methodReferences"] = []
    if apple_raw:
        for reference in re.findall(r"\{\{Refdevice\|(.*?)\}\}", apple_raw, re.S):
            attributes = dict(re.findall(r"(?:^|\|)([a-z]+)=([^|]*)", reference))
            apple["methodReferences"].append({
                key: attributes.get(key) for key in
                ("date", "device", "os", "method", "store", "version", "framerate")
            })
    apple["noteSignals"] = {}
    for method in ("crossover", "wine"):
        match = re.search(
            r"^\|[ \t]*" + method + r" notes[ \t]*=[ \t]*(.*?)(?=^\|[ \t]*\w|^\}\})",
            apple_raw or "", re.M | re.S,
        )
        note = match.group(1) if match else ""
        apple["noteSignals"][method] = {
            "mentionsCrashOrFreeze": bool(re.search(r"crash|freez", note, re.I)),
            "mentionsUnplayable": bool(re.search(r"unplayable|can't run|won't start", note, re.I)),
            "mentionsLowFPS": bool(re.search(r"low fps|fps is low|10-15", note, re.I)),
            "mentionsDRM": bool(re.search(r"\bDRM\b|denuvo", note, re.I)),
            "mentionsGPTK": bool(re.search(r"game porting toolkit|\bGPTK\b", note, re.I)),
            "mentionsWhisky": bool(re.search(r"whisky", note, re.I)),
        }
    apple["status"] = "reported" if apple["ratings"] else "unavailable-or-no-rating"
    apple["identityBasis"] = "Exact title page candidate; Steam app ID must match when present."
    expected = re.search(r"/app/(\d+)", row.get("releaseEvidenceSource") or "")
    steam_id = expected.group(1) if expected else None
    observed = re.search(r"^\|[ \t]*steam appid[ \t]*=[ \t]*(\d+)", apple_raw or "", re.M)
    apple["steamAppId"] = observed.group(1) if observed else None
    if steam_id and apple["steamAppId"] and steam_id != apple["steamAppId"]:
        apple["ratings"] = {}
        apple["status"] = "identity-mismatch"

    cw_match = re.search(r"^\|[ \t]*codeweavers[ \t]*=[ \t]*([^\s|}]+)", apple_raw or "", re.M)
    cw_slug = cw_match.group(1) if cw_match else None
    if not cw_slug or cw_slug.startswith("|"):
        cw_slug = re.sub(r"[^a-z0-9]+", "-", urllib.parse.unquote(slug).lower()).strip("-")
        cw_identity = "Title-derived candidate URL, not an established database entry."
    else:
        cw_identity = "CodeWeavers slug linked by the AppleGamingWiki title page."
    if store_id in CW_SLUGS:
        cw_slug = CW_SLUGS[store_id]
        cw_identity = "Exact 2D/Pixel Remaster listing located via indexed search; not the FFIV 3D listing."
    cw_url = f"https://www.codeweavers.com/compatibility/crossover/{cw_slug}"
    if previous and previous["codeWeavers"]["httpStatus"] == 403:
        cw = dict(previous["codeWeavers"])
        attempted_url = cw.get("blockedAttemptUrl", cw["url"])
        cw["url"] = cw_url
        cw["urlChangedSinceBlockedAttempt"] = attempted_url != cw_url
        cw["blockedAttemptUrl"] = attempted_url
        cw_raw = None
    else:
        cw, cw_raw = fetch(cw_url)
    cw["rating"] = None
    cw["identityBasis"] = cw_identity
    cw["status"] = "unavailable"
    if cw_raw:
        cw["status"] = "requires-manual-rating-review"
        if "Just a moment" in cw_raw or "cf-chl" in cw_raw:
            cw["status"] = "challenge-no-rating"

    if steam_id:
        proton, proton_raw = fetch(
            f"https://www.protondb.com/api/v1/reports/summaries/{steam_id}.json"
        )
        proton["summary"] = json.loads(proton_raw) if proton_raw else None
        if proton["summary"] and proton["summary"].get("tier") not in TIER_VALUES:
            raise ValueError(f"{store_id}: unexpected ProtonDB tier")
        proton["reportUrl"] = f"https://www.protondb.com/app/{steam_id}"
        steam, steam_raw = fetch(
            f"https://store.steampowered.com/api/appdetails?appids={steam_id}&l=english"
        )
        details = json.loads(steam_raw)[steam_id] if steam_raw else None
        data = details.get("data", {}) if details and details.get("success") else {}
        steam["name"] = data.get("name")
        steam["drmNotice"] = data.get("drm_notice")
        steam["externalAccountNotice"] = data.get("ext_user_account_notice")
        steam["noticeAbsenceProvesDRMFree"] = False
    else:
        proton = {
            "url": "https://www.protondb.com/", "summary": None,
            "reportUrl": None, "checkedAt": apple["checkedAt"],
            "error": "Minecraft Java has no matching Steam app; no proxy substituted.",
        }
        steam = None
    return {
        "storeId": store_id, "title": row["title"], "originalRank": row["rank"],
        "steamAppId": steam_id, "appleGamingWiki": apple, "codeWeavers": cw,
        "protonDB": proton, "steamDRM": steam,
        "proxyScope": "PC/Steam version or explicitly scoped native macOS entry, "
        "not Xbox/MSIXVC runtime, entitlement, sign-in or gameplay qualification.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true", help="Read public endpoints; otherwise normalize the existing snapshot offline")
    args = parser.parse_args()
    queue = load_json(DATA / "next-30-queue.json")["items"]
    if len(queue) != len(SLUGS):
        raise ValueError("Queue/slug count changed")
    output = DATA / "wine-proxy-evidence-v1.json"
    previous = {
        row["storeId"]: row for row in load_json(output)["items"]
    } if output.exists() else {}
    if args.refresh:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            items = list(pool.map(
                lambda pair: collect(pair[0], pair[1], previous.get(pair[0]["storeId"])),
                zip(queue, SLUGS),
            ))
    else:
        if [row["storeId"] for row in queue] != list(previous):
            raise ValueError("Existing snapshot identities/order differ from queue")
        items = list(previous.values())
    for item in items:
        if item["steamDRM"]:
            item["steamDRM"].pop("legalNotice", None)
    result = {
        "schemaVersion": 1, "readOnlyCollection": True, "gameLaunches": 0,
        "sourcePolicy": "HTTP receipts and extracted fields only; unavailable "
        "sources yield null, never a rating inferred from search summaries.",
        "items": items,
    }
    output.write_text(
        json.dumps(result, indent=2, ensure_ascii=True) + "\n"
    )
    for item in items:
        print(item["originalRank"], item["title"],
              item["appleGamingWiki"]["ratings"],
              (item["protonDB"]["summary"] or {}).get("tier"),
              item["codeWeavers"]["httpStatus"])


if __name__ == "__main__":
    main()
