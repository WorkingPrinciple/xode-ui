#!/usr/bin/env python3
"""Build the v5 expansion and discovery preflights from frozen public evidence."""

import argparse
import copy
import hashlib
import json
import re
from pathlib import Path
from build_fast_path_packets import FIELDS
from inspect_queue import DATA, load_json

ORDER = (
    "9P9VNSQK1W3K", "9P8NSTDMZ11P", "9MSVVM5NS9L6",
    "9PBWWQGXVMKC", "9NLRT31Z4RWM", "9NMNMS626R59",
    "9PD5BM2Z8C4L", "9MXND4PQLK3W", "9P1Z43KRNQD4",
)
PROFILES = {
    "9P9VNSQK1W3K": "queue-winecx-nativejson",
    "9P8NSTDMZ11P": "creation-dx11-d3dmetal",
    "9MSVVM5NS9L6": "creation-dx11-d3dmetal",
    "9PBWWQGXVMKC": "creation-dx11-d3dmetal",
    "9NLRT31Z4RWM": "creation-dx11-d3dmetal",
    "9NMNMS626R59": "queue-winecx-nativejson",
    "9PD5BM2Z8C4L": "creation-dx11-d3dmetal",
    "9MXND4PQLK3W": "queue-winecx-nativejson",
    "9P1Z43KRNQD4": None,
}
SOURCES = {
    "dredge": ("https://www.gamepressure.com/dredge-pc/how-to-save-the-game/zc10a4f",
               "Cross-platform save guide",
               "Dock, Pause > Save and Quit, confirm. Continue or Load / New "
               "selects previous progress. At sea Quit need not save."),
    "tunic": ("https://tryhardguides.com/how-to-save-in-tunic/",
              "Cross-platform save guide",
              "Flame-lit shrines force checkpoint saves and restore health/magic; "
              "enemies respawn. Periodic autosaves also reported."),
    "monster": ("https://leetguides.blogspot.com/2019/09/monster-sanctuary-tips-and-qol-info.html",
                "Community guide, early PC version; verify current Store prompts",
                "Exploration screen transitions autosave; menu Save and Quit saves "
                "and returns to menu. No forced-close workaround proposed."),
    "inscryption": ("https://www.polygon.com/reviews/22787516/inscryption-review-no-spoilers-pc-horror-card-games/",
                   "PC review, narrative/menu mechanic proxy",
                   "First launch intentionally disables New Game; select Continue. "
                   "It is not a corrupt-save symptom or retention proof."),
    "halls": ("https://progameguides.com/halls-of-torment/halls-of-torment-tips-tricks-guide/",
              "Early PC gameplay guide; not Store save-system documentation",
              "Runs up to 30 minutes; gold buys camp blessings, quests unlock "
              "after first run. Does not prove current mid-run save/resume."),
    "doom64": ("https://www.trueachievements.com/game/DOOM-64/walkthrough",
               "2020 remaster Xbox controls, not N64 original",
               "Left stick move, right stick horizontal aim, RT fire, A use, "
               "Start pause. Password/cheat steps intentionally excluded."),
    "vampire-controls": ("https://www.gamepressure.com/newsroom/vampire-survivors-controls-explained/z14ebf",
                         "PC/Xbox controls guide",
                         "WASD or left stick movement; attacks automatic; mouse "
                         "menu selection or D-pad/stick plus A on Xbox."),
    "tunic-opening": ("https://www.trueachievements.com/game/Tunic/walkthrough/3",
                      "Xbox walkthrough opening; secret codes deliberately excluded",
                      "Starts controllable on beach; ramp leads inland. A opens "
                      "chests, LB inventory, X/Y/B bind item. No secret/warp route used."),
}
SAVE_PATHS = {
    "9P8NSTDMZ11P": r"%LOCALAPPDATA%\Packages\DevolverDigital.Inscryption_6kzv4j18v0c96\SystemAppData\wgs",
    "9NLRT31Z4RWM": r"%LOCALAPPDATA%\Packages\Finji.TUNIC_tys0ffscxatjj\SystemAppData\wgs",
    "9PD5BM2Z8C4L": r"%LOCALAPPDATA%\Packages\poncle.VampireSurvivors_9pv5cyp4vwdsr\SystemAppData\wgs\<user-id>",
    "9MXND4PQLK3W": r"%LOCALAPPDATA%\Packages\BethesdaSoftworks.Doom641997_3275kfvn8vcwc\SystemAppData\wgs",
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cite(key):
    url, scope, finding = SOURCES[key]
    return {"url": url, "scope": scope, "finding": finding, "checkedAt": "2026-10-22"}


def phase(value, source):
    return {"value": value, "status": "unknown" if value is None else "public-expectation",
            "sources": [source], "limitation": "Public proxy, not observed Store input/retention."}


def fast_path(row):
    source = row["public"]["pcgamingwiki"]
    fallback = {"url": source["url"], "checkedAt": source["checkedAt"],
                "scope": "Inspected exact-title PCGamingWiki article",
                "finding": "No exact first-save/input/skip instruction admitted for this phase."}
    phases = {key: phase(None, fallback) for key in FIELDS}
    facts = "\n".join(source["facts"])
    if re.search(r"^\|mouse menu[ \t]*=[ \t]*true", facts, re.M):
        phases["keyboard_controls"] = phase(
            "Mouse menu navigation documented; exact title-to-gameplay and "
            "movement/confirm keys unconfirmed. Follow visible prompts.",
            {**fallback, "finding": "PCGamingWiki Input table explicitly reports mouse menu support."})
    if re.search(r"^\|xinput controllers[ \t]*=[ \t]*true", facts, re.M):
        phases["gamepad_alternative"] = phase(
            "XInput controller support documented; exact button sequence "
            "unconfirmed. Use displayed prompts, not another game's binding.",
            {**fallback, "finding": "PCGamingWiki Input table explicitly reports XInput support."})
    warnings = ["Use displayed prompts for unknown keys; no console, cheats, mods, "
                "logo-file changes, save overwrite or assumed Continue retention."]
    sid = row["storeId"]
    if sid == "9P8NSTDMZ11P":
        phases["title_to_gameplay"] = phase(
            "Choose Continue (New Game is intentionally locked). Follow the "
            "opening card-game instructions; exact keyboard sequence and "
            "earliest persistent save remain unknown.", cite("inscryption"))
        warnings.append("Continue exists even before first gameplay: its label is NOT retention evidence.")
    if sid == "9MSVVM5NS9L6":
        for key, value in {
            "save_trigger": "At a dock, pause > Save and Quit and confirm. "
                            "Do not test persistence by quitting at sea. First dock unlock/time unknown.",
            "quit": "Dock > Pause > Save and Quit > confirm returns to main menu.",
            "relaunch_indicator": "Continue loads latest, or Load / New selects an existing campaign. "
                                  "Load test slot and compare dock/progress; never Delete or overwrite.",
        }.items():
            phases[key] = phase(value, cite("dredge"))
    if sid == "9PBWWQGXVMKC":
        phases["save_trigger"] = phase(
            "Cross an exploration-screen boundary and wait for autosaving; "
            "or menu > Save and Quit. Earliest opening enablement/time unconfirmed.", cite("monster"))
        phases["quit"] = phase("Menu > Save and Quit. Exact menu-open key unknown.", cite("monster"))
    if sid == "9NLRT31Z4RWM":
        phases["title_to_gameplay"] = phase(
            "Opening starts with fox controllable on beach; take ramp inland. "
            "Exact title-screen activation unknown. Do not use walkthrough's "
            "secret code/teleporter detour.", cite("tunic-opening"))
        phases["gamepad_alternative"] = phase(
            "A opens chests; LB inventory; assign found stick to X/Y/B then "
            "that button attacks. Follow displayed movement prompts.",
            cite("tunic-opening"))
        phases["save_trigger"] = phase(
            "Interact with a flame-lit shrine to checkpoint; enemies respawn. "
            "Exact first-shrine route/key/time unconfirmed.", cite("tunic"))
    if sid == "9NMNMS626R59":
        phases["save_trigger"] = phase(None, cite("halls"))
        warnings.append("Verify persistent meta-progression, not an assumed resumable run. "
                        "Guide's 30-minute run length is not first-save latency.")
    if sid == "9MXND4PQLK3W":
        phases["gamepad_alternative"] = phase(
            "Left stick movement, right stick horizontal aim, RT fire, A use, Start pause. "
            "No password/cheat route.", cite("doom64"))
    if sid == "9PD5BM2Z8C4L":
        phases["keyboard_controls"] = phase(
            "WASD movement; attacks occur automatically. Mouse selects menus/items. "
            "Exact fresh-character/stage menu sequence unknown.", cite("vampire-controls"))
        phases["gamepad_alternative"] = phase(
            "Left stick move; D-pad/stick navigates menus and A confirms. "
            "Verify installed-build prompts.", cite("vampire-controls"))
    return {"storeId": sid, "title": row["title"], "phases": phases, "warnings": warnings}


def build(inputs):
    evidence = inputs["evidence"]
    by_id = {row["storeId"]: row for row in evidence["items"]}
    catalogue = load_json(DATA / "game-compatibility-v1.json")["products"]
    items = []
    for rank, sid in enumerate(ORDER, 1):
        row = copy.deepcopy(by_id[sid])
        size = row["downloadSizeBytes"]
        tier = row["public"].get("protonDB", {}).get("summary") or {}
        if not 0 < size <= 8 * 2**30 or tier.get("tier") not in {"platinum", "gold"}:
            raise ValueError(f"{sid}: size/proxy gate failed")
        if sid in inputs["excludedMatrixIds"]:
            raise ValueError(f"{sid}: already in matrix")
        row.update(rank=rank, packageFormat="MSIXVC", numericProbability=None,
                   profileProposal={"name": PROFILES[sid], "status": "candidate-not-game-qualified"},
                   save_path=SAVE_PATHS.get(sid), saveLocation=None, windowTitle=None,
                   save_path_scope="Explicit Microsoft Store row only; null if only general PC path "
                   "is known. Never expand to a guessed host/Wine directory.",
                   antiCheat=catalogue[sid]["antiCheat"],
                   antiCheatEvidence=catalogue[sid]["antiCheatEvidence"],
                   supported01=catalogue[sid]["supported01"],
                   fastPath=fast_path(row))
        row["saveEvidence"] = {
            "url": row["public"]["pcgamingwiki"]["url"],
            "checkedAt": row["public"]["pcgamingwiki"]["checkedAt"],
            "facts": [fact for fact in row["public"]["pcgamingwiki"]["facts"]
                      if "saves|" in fact or "xbox cloud" in fact],
            "limitation": "Cloud support does not prove local runtime sync. "
            "General Windows/Steam paths are separate proxies, not Store paths.",
        }
        items.append(row)
    return {
        "schemaVersion": 5, "scope": "Nine additional research candidates; v4 and "
        "six-title preflight remain immutable and are NOT superseded.",
        "baseV4": inputs["baseV4"], "collectionInputs": inputs,
        "rankingPolicy": "Ordinal judgment: positive Windows-on-Mac reports, Proton "
        "sample/tier, simpler API, small size. Not calibrated probabilities or "
        "gameplay qualification; popular means established PC titles with public "
        "report activity, not measured Game Pass player counts.",
        "rankCaveats": {
            "Brotato": "Best public proxy; frozen installer UTF-16 parser panic held by S2.",
            "Vampire Survivors": "Proton Platinum but Apple wiki CrossOver unplayable vs Wine perfect; "
                                 "native success is NOT a Windows Store result.",
            "Quake": "Enhanced edition uses Vulkan by default. Shared Steam ID reports "
                     "may cover original/remaster; no original-version Mac rating substituted. "
                     "Explicit D3D11 alternative needs S1 approval, not automatic flags.",
            "TUNIC": "Native Mac rating does not establish Windows compatibility; Proton proxy only.",
        },
        "rejected": [
            {"title": "Pentiment", "reason": "Fresh catalogue 10.665 GiB exceeds 8 GiB cap."},
            {"title": "DOOM + DOOM II", "reason": "No exact admitted Steam/Proton identity from collector."},
            {"title": "Fallout", "reason": "No admitted exact public positive proxy; avoid weak identity match."},
        ],
        "installPolicy": {"maximumSerialInstallers": 1, "budgetBytes": 20 * 2**30,
                          "minimumFreeBytes": 150 * 2**30, "stagingMarginBytes": 2 * 2**30,
                          "stopOnLoginOrPurchase": True, "deletions": False,
                          "gameLaunches": 0, "unknownAntiCheatIsNotNone": True},
        "workingTarget": 20, "verifiedWorkingAtMatrixSnapshot": inputs["workingIds"],
        "items": items,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    output = DATA / "s3-ready-packets-v5.json"
    if args.refresh:
        matrix = Path("/Users/dragoshont/.copilot/session-state/"
                      "24963110-1b48-4e35-bae1-a54927543f42/files/s3-tried-games.json")
        snapshot = load_json(matrix)
        inputs = {"evidence": load_json(DATA / "small-game-evidence-v1.json"),
                  "baseV4": {"path": "s3-ready-packets-v4.json",
                             "sha256": sha(DATA / "s3-ready-packets-v4.json")},
                  "matrix": {"path": str(matrix), "sha256": sha(matrix),
                             "updatedAt": snapshot["updatedAt"]},
                  "excludedMatrixIds": [row["productId"] for row in snapshot["games"]],
                  "workingIds": snapshot["workingAdmission"]["qualifiedProductIds"]}
        if output.exists():
            selected = load_json(output)["collectionInputs"]
            for key in ("matrix", "excludedMatrixIds", "workingIds"):
                inputs[key] = selected[key]
        output.write_text(json.dumps(build(inputs), indent=2, ensure_ascii=True) + "\n")
    else:
        packet = load_json(output)
        if packet != build(packet["collectionInputs"]):
            raise ValueError("V5 differs from frozen inputs")
    print("Nine <=8 GiB candidates; no gameplay/support verdict")


if __name__ == "__main__":
    main()
