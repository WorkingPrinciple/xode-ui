#!/usr/bin/env python3
"""Add dated public save/exit research to the frozen packet, entirely offline."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path

from inspect_queue import DATA, load_json


CHECKED_AT = "2026-10-22"
FIELDS = (
    "save_path", "save_pattern", "xbox_cloud", "window_title", "window_class",
    "quit", "tutorial_save_gate",
)
PCGW = "https://www.pcgamingwiki.com/wiki/"
TITLES = [
    ("9PNG83MDD6SH", "Limbo", True,
     r"%LOCALAPPDATA%\Packages\16902PlaydeadAPS.PlaydeadsLIMBO_2m6wzp0cmt084\SystemAppData\wgs"),
    ("9MWR1NC6VQ6L", "Stardew_Valley", True, None),
    ("9NV3L234VGXD", "Replaced", True,
     r"%LOCALAPPDATA%\Packages\Thunderful.REPLACED-Game_8j53pwgd019sy\SystemAppData\wgs"),
    ("9NH0MSG29X6L", "Mixtape", True,
     r"%LOCALAPPDATA%\Packages\AnnapurnaInteractive.BlueMoonLagoon_c96c51jf6wkvm\SystemAppData\wgs"),
    ("9PJPCB188SVG", "Subnautica_2", True, None),
    ("9P2J5D12GJL5", "The_Elder_Scrolls_IV:_Oblivion", False, None),
    ("9P3T7HVKM6D0", "Kingdom_Come:_Deliverance", False, None),
    ("9P03JGQ4S1GC", "The_Elder_Scrolls_V:_Skyrim_Special_Edition", False, None),
    ("9N8C07SS8C9D", "Final_Fantasy_IV", True, None),
    ("9NGH1FK0RJGL", "Wasteland_Remastered", True, None),
    ("9P1N07XDL1D4", "Dishonored", True,
     r"%USERPROFILE%\Documents\My Games\Dishonored\DishonoredGame\SaveData"),
    ("9NFB47H2SDRX", "Forever_Ago", True,
     r"%LOCALAPPDATA%\Packages\57209AnnapurnaInteractive.ForeverAgo_c96c51jf6wkvm\SystemAppData\wgs"),
    ("9P5Z4530318L", "Deathloop", True,
     r"%USERPROFILE%\AppData\Local\Packages\BethesdaSoftworks.ProjectPrism_3275kfvn8vcwc\SystemAppData\wgs\<user-id>\<user-id>"),
    ("9NXWSWBM4H6T", "Beast_of_Reincarnation", True,
     r"%LOCALAPPDATA%\Packages\Fictions.ProjectAibou_qj8vnfjar8dk2\SystemAppData\wgs"),
    ("9NCJWHHMVHR0", "Keeper", True,
     r"%LOCALAPPDATA%\Packages\Microsoft.PaganIdol_8wekyb3d8bbwe\SystemAppData\wgs"),
    ("9NQVHHW88XW9", "Bluey%27s_Happy_Snaps", None, None),
]

SAVE_GAPS = {
    "9MWR1NC6VQ6L": (
        r"PCGamingWiki lists %APPDATA%\StardewValley\Saves\ for Windows, not an "
        "explicit Microsoft Store save row. Store-specific forum confirmation "
        "could not be fetched; do not replace it with an assumed WGS path."
    ),
    "9PJPCB188SVG": (
        r"PCGamingWiki lists %LOCALAPPDATA%\Subnautica2\Saved\SaveGames\ for "
        "Windows; only its configuration rows distinguish Windows/WinGDK. "
        "Official support confirms local PC/Xbox saves and optional platform "
        "cloud backup but gives no path. Store-specific directory unconfirmed."
    ),
    "9P2J5D12GJL5": (
        r"Original Oblivion: Windows row is %USERPROFILE%\Documents\My Games"
        r"\Oblivion\Saves\; Microsoft Store row is empty. Remastered/ProjectAltar "
        "results are a different game and are not admitted."
    ),
    "9P3T7HVKM6D0": (
        r"Windows row is %USERPROFILE%\Saved Games\kingdomcome\saves\; Microsoft "
        "Store row is empty. Sequel and generic Game Pass WGS results are not "
        "evidence for this first-game Store build."
    ),
    "9P03JGQ4S1GC": (
        "PCGamingWiki's Microsoft Store save row is empty. Bethesda answer "
        "41673 gives Documents/My Games/Skyrim Special Edition/Saves for Windows "
        "without identifying the Store build. Do not accept an uncited "
        "SkyrimSE-PC WGS substitution."
    ),
    "9N8C07SS8C9D": (
        r"PCGamingWiki's Windows path explicitly includes FINAL FANTASY IV PR"
        r"\Steam\<user-id>; it does not establish an Xbox path. No title-specific "
        "Store path was verified; generic WGS converter guidance is insufficient."
    ),
    "9NGH1FK0RJGL": (
        "PCGamingWiki's Microsoft Store saves row is empty. The Windows saves "
        "row under LocalLow/InXile Entertainment and the Store language config "
        "under LocalLow/Microsoft are not an explicit Store save location."
    ),
    "9NQVHHW88XW9": (
        "PCGamingWiki stub has an empty Windows save row and no Store save "
        "location. Xbox Play Anywhere availability alone does not establish "
        "the local save path, WGS implementation or filenames."
    ),
}


def evidence(value, url, scope, finding, *, known=True):
    return {
        "value": value,
        "status": "public-expectation" if known else "unknown",
        "sources": [{
            "url": url,
            "checkedAt": CHECKED_AT,
            "scope": scope,
            "finding": finding,
        }],
    }


def add_source(field, url, scope, finding):
    field["sources"].append({
        "url": url, "checkedAt": CHECKED_AT, "scope": scope, "finding": finding,
    })


def research():
    rows = {}
    for store_id, slug, cloud, path in TITLES:
        url = PCGW + slug + "?action=raw"
        fields = {
            field: evidence(
                None, url, "PCGamingWiki title article",
                "Not confirmed in inspected title source; do not infer from "
                "the marketing name, engine, another edition or another store.",
                known=False,
            )
            for field in FIELDS
        }
        fields["save_path"] = evidence(
            path, url, "Microsoft Store save-game data location row",
            "Explicit Store save directory; Windows variables and account "
            "placeholders are unresolved, not a host/Wine path."
            if path else SAVE_GAPS[store_id],
            known=path is not None,
        )
        fields["xbox_cloud"] = evidence(
            cloud, url, "Save game cloud syncing / xbox cloud",
            "PCGamingWiki reports Xbox cloud support; not proof of Wine/runtime "
            "sync or PC-to-console cross-save."
            if cloud is not None else
            "Xbox cloud field is blank. Do not substitute the Steam Cloud flag.",
            known=cloud is not None,
        )
        rows[store_id] = fields

    stardew_forum = (
        "https://forums.stardewvalley.net/threads/"
        "move-saves-from-xbox-game-pass-to-steam-windows.11152/"
    )
    add_source(
        rows["9MWR1NC6VQ6L"]["save_path"], stardew_forum,
        "Official forum, community Game Pass-to-Steam discussion",
        "Fetch returned HTTP 503, including alternate query; no page content "
        "admitted from search-generated path claims.",
    )
    add_source(
        rows["9MWR1NC6VQ6L"]["save_pattern"],
        "https://stardewvalleywiki.com/Saves", "Official wiki",
        "HTTP 403, including raw/alternate-host attempts; Store-specific file "
        "pattern not verified. Do not assume retail XML files or WGS blobs.",
    )
    add_source(
        rows["9PJPCB188SVG"]["save_path"],
        "https://support.subnautica.com/hc/en-us/articles/"
        "57019990000281-Where-are-my-saved-games-stored",
        "Official PC/Xbox support",
        "Local device storage and optional platform cloud are confirmed; no "
        "directory or file pattern is specified.",
    )
    add_source(
        rows["9P03JGQ4S1GC"]["save_path"],
        "https://help.bethesda.net/app/answers/detail/a_id/41673/",
        "Official Windows Skyrim/Skyrim Special Edition support",
        "Documents/My Games/Skyrim Special Edition/Saves is documented for "
        "Windows, but the answer does not identify Microsoft Store.",
    )
    add_source(
        rows["9N8C07SS8C9D"]["tutorial_save_gate"],
        "https://support.na.square-enix.com/faqarticle.php?"
        "kid=69476&id=9341&page=0&sc=0",
        "Square Enix FAQ search result, edition applicability unverified",
        "Fetch returned HTTP 503. Not admitted as FFIV Pixel Remaster guidance.",
    )

    limbo = (
        "https://steamcommunity.com/app/48000/discussions/0/"
        "4997318143967408652/?l=english#c4997318143967537515"
    )
    rows["9PNG83MDD6SH"]["tutorial_save_gate"] = evidence(
        "Automatic checkpoints, generally after each puzzle area; previous "
        "checkpoints can be replayed. Exact first checkpoint and elapsed time "
        "are not established.", limbo, "Steam community gameplay report",
        "Reply describes automatic puzzle-area checkpoints. This is an expected "
        "gameplay mechanic, not a Store/Wine save-retention observation.",
    )

    stardew = (
        "https://steamcommunity.com/app/413150/discussions/0/"
        "133259956002640807/?l=english"
    )
    rows["9MWR1NC6VQ6L"]["tutorial_save_gate"] = evidence(
        "Sleep in the farmhouse bed to end the day; wait for the next day/save "
        "to finish before quitting. No confirmed elapsed-time bound.",
        stardew, "Steam community gameplay reports",
        "Replies agree that sleeping ends the day and autosaves. Exact current "
        "Xbox-build behavior has not been exercised.",
    )
    rows["9MWR1NC6VQ6L"]["quit"] = evidence(
        "After the overnight save: open the game menu (E), select its far-right "
        "exit tab, then exit the game.", stardew,
        "Steam community PC menu report",
        "Reply documents menu E / far-right tab / exit. Public expectation only; "
        "no exact localized button label or current Store observation.",
    )

    subnautica = (
        "https://steamcommunity.com/app/1962700/discussions/0/"
        "834999523153739631/?l=english"
    )
    rows["9PJPCB188SVG"]["tutorial_save_gate"] = evidence(
        "Manual and autosave slots are reported separately. Use Load Game to "
        "select the manual save rather than assuming Continue selects it. "
        "Earliest tutorial save availability/time unconfirmed.",
        subnautica, "Steam Early Access community reports",
        "Thread distinguishes manual/autosave slots and latest-save Continue; "
        "not a guarantee for the frozen Store package.",
    )
    rows["9PJPCB188SVG"]["quit"] = evidence(
        "Esc menu -> Exit without saving is reported; create the intended "
        "manual save first. Full Store desktop-exit chain unconfirmed.",
        subnautica + "#c834999523153743107", "Steam community PC menu report",
        "Reply explicitly names Esc menu and Exit without saving. The source "
        "does not establish an exact Store window or current menu labels.",
    )

    oblivion = (
        "https://archive.org/download/obliv_goty_pc_man-v2/"
        "obliv_goty_pc_man-v2_djvu.txt"
    )
    rows["9P2J5D12GJL5"]["quit"] = evidence(
        "In-game menu -> Quit returns to the Start screen; Main Menu -> Exit "
        "exits the game. Save first.", oblivion,
        "Bethesda original Oblivion GOTY PC manual, page 3; archival OCR",
        "Manual distinguishes in-game Quit from main-menu Exit. Not Remastered.",
    )
    rows["9P2J5D12GJL5"]["tutorial_save_gate"] = evidence(
        "The in-game menu exposes Save for the current game. The manual does "
        "not establish the earliest tutorial save or a time-to-save bound.",
        oblivion, "Bethesda original Oblivion GOTY PC manual, page 3",
        "Manual documents Save. Search claims that saving requires leaving "
        "the sewers were not established by the inspected manual and are omitted.",
    )

    kcd = (
        "https://www.trueachievements.com/game/"
        "Kingdom-Come-Deliverance/walkthrough/2"
    )
    rows["9P3T7HVKM6D0"]["quit"] = evidence(
        "Pause menu -> Save & exit to menu. This returns to menu, not a confirmed "
        "desktop exit; the previous exit save is overwritten.",
        kcd, "Xbox first-game community walkthrough / Saving",
        "Walkthrough names Save & exit to menu and its overwrite behavior.",
    )
    rows["9P3T7HVKM6D0"]["tutorial_save_gate"] = evidence(
        "Normal-mode quest milestones may autosave. Manual Save Game consumes "
        "Saviour Schnapps; eligible Sleep and Save beds also save. The guide "
        "identifies freely usable beds after Awakening, not the earliest save "
        "or a measured tutorial duration.", kcd,
        "Xbox first-game community walkthrough / Saving",
        "Documents four save methods: Schnapps, sleep, exit-save, normal autosave.",
    )
    add_source(
        rows["9P3T7HVKM6D0"]["tutorial_save_gate"],
        "https://www.gamerguides.com/kingdom-come-deliverance/guide/"
        "introduction/useful-gameplay-tips/saving-carefully",
        "First-game gameplay guide",
        "Eligible beds save; Schnapps permits saving outside combat.",
    )

    rows["9P03JGQ4S1GC"]["window_title"] = evidence(
        "Skyrim Special Edition",
        "https://raw.githubusercontent.com/hon0/AutoHotKey_Script/master/"
        "Skyrim_Special_Edition.ahk",
        "Public community script, PC edition/store unspecified",
        "Script uses WinActive(\"Skyrim Special Edition\") with "
        "SetTitleMatchMode, 2 (substring). Not evidence of the exact complete "
        "title, a window class or Microsoft Store/Wine window identity.",
    )
    rows["9P03JGQ4S1GC"]["tutorial_save_gate"] = evidence(
        "Journal -> System -> Save creates a manual save; F5 is the PC "
        "quicksave default. Earliest tutorial availability/time unconfirmed.",
        "https://howtovideogame.com/skyrim-elder-scrolls-v-how-to-save-your-game/",
        "PC/console Skyrim Special Edition/Anniversary Edition gameplay guide",
        "Guide documents manual and quicksave controls, not a Store launch result.",
    )

    dishonored = PCGW + "Dishonored?action=raw"
    rows["9P1N07XDL1D4"]["save_pattern"] = evidence(
        "*.sav", dishonored,
        "PCGamingWiki general save conversion between versions",
        "Article identifies .sav files and uses a *.sav filter in its general "
        "conversion section. This is not an exhaustive runtime file inventory.",
    )
    rows["9P1N07XDL1D4"]["tutorial_save_gate"] = evidence(
        "Manual saves, automatic mission saves, autosaves and a quicksave slot "
        "are documented. Earliest tutorial save availability/time unconfirmed.",
        dishonored, "PCGamingWiki save data section",
        "Article documents 40 manual, 9 automatic mission, 2 autosave and "
        "1 quicksave slot; no measured first-save timing.",
    )
    rows["9P1N07XDL1D4"]["xbox_cloud"]["sources"][0]["finding"] += (
        " Article explicitly says PC saves do not sync with Xbox console."
    )

    rows["9NFB47H2SDRX"]["tutorial_save_gate"] = evidence(
        "Checkpoint autosaves only; no manual save. First checkpoint/time is "
        "not identified. New Game overwrites the current save.",
        "https://gamingtrend.com/reviews/forever-ago-review/",
        "Publisher-provided PS5 review; cross-platform mechanic expectation",
        "Reviewer explicitly describes checkpoint autosaves and no manual save. "
        "Not verified on the Microsoft Store build.",
    )

    deathloop = PCGW + "Deathloop?action=raw"
    rows["9P5Z4530318L"]["save_pattern"] = evidence(
        "Two long numerical filenames without extensions inside the account/"
        "container directory; literal names vary.", deathloop,
        "PCGamingWiki Microsoft Store/Game Pass transfer section, steps 3-4",
        "Store files are explicitly extensionless; do not use Steam's "
        "save.dloop/title.data as a Store filesystem glob.",
    )
    rows["9P5Z4530318L"]["tutorial_save_gate"] = evidence(
        "Let the first cutscene play through to create an initial Store save "
        "(PCGamingWiki transfer instructions). No manual save; later quit "
        "within an area can discard that area's progress. Elapsed time unknown.",
        deathloop, "Microsoft Store-specific save-creation instructions",
        "Transfer instructions explicitly require the initial cutscene to finish.",
    )
    add_source(
        rows["9P5Z4530318L"]["tutorial_save_gate"],
        "https://www.gosunoob.com/deathloop/save-deathloop/",
        "General gameplay save/quit guide",
        "Describes loadout/level-transition autosaves and loss of within-area "
        "progress on quit/crash; not an exact quit-menu path.",
    )

    beast = "https://game8.co/games/Beast-of-Reincarnation/archives/614598"
    rows["9NXWSWBM4H6T"]["quit"] = evidence(
        "Menu -> Settings -> Other -> Return to Title. The same menu also "
        "offers quitting the game; exact quit-button label is not transcribed.",
        beast, "Illustrated gameplay guide / How to Quick Save",
        "Guide explicitly documents this title-return path and says the same "
        "menu can quit the game. No Store/Wine observation.",
    )
    rows["9NXWSWBM4H6T"]["tutorial_save_gate"] = evidence(
        "Manual saves at campsites or the Cleanse Walker Attribute Portal. "
        "Autosaves at camp rest, cutscenes/events; Return to Title triggers a "
        "quick autosave. Earliest unlock/time unconfirmed.", beast,
        "Illustrated gameplay save guide",
        "Guide documents save mechanisms, not a measured first tutorial gate.",
    )

    add_source(
        rows["9NCJWHHMVHR0"]["tutorial_save_gate"],
        "https://www.doublefine.com/games/support/keeper",
        "Official Keeper support page",
        "Page lists platforms/features but gives no checkpoint or quit-save "
        "mechanics. Generic Double Fine/Psychonauts guidance is not admitted.",
    )
    return rows


def build_packet(base):
    packet = copy.deepcopy(base)
    researched = research()
    ids = [row["storeId"] for row in packet["items"]]
    if ids != list(researched):
        raise ValueError("Research identities/order differ from the frozen sixteen-title packet")
    packet["schemaVersion"] = 2
    packet["publicResearchCheckedAt"] = CHECKED_AT
    packet["basePacket"] = {
        "path": "s3-ready-packets-v1.json",
        "sha256": hashlib.sha256((DATA / "s3-ready-packets-v1.json").read_bytes()).hexdigest(),
        "readinessRefreshed": False,
    }
    packet["publicResearchContract"] = {
        "save_path": "Nullable symbolic Windows Microsoft Store save directory, "
        "not an absolute macOS save-dir. Resolve/observe in the title prefix "
        "before passing --save-dir. Never create it to make a check pass.",
        "save_pattern": "Nullable public filename/pattern description, NOT a "
        "guaranteed exhaustive glob. Do not execute or use it to omit evidence.",
        "xbox_cloud": "Nullable public Xbox cloud capability; not observed sync "
        "under the frozen runtime. It does not imply WGS or console cross-save.",
        "save_path_uses_wgs": "Derived only from a confirmed save_path containing "
        "SystemAppData/wgs, not inferred from Xbox cloud support.",
        "window_title": "Nullable PUBLIC expectation; Skyrim is only a "
        "community-script substring. Not safe as an exact WM_CLOSE selector.",
        "window_class": "Nullable public expected class; no engine-default guesses.",
        "quit": "Nullable cited menu path; a return-to-menu path does not imply "
        "desktop exit. S3 must verify current build/localization.",
        "tutorial_save_gate": "Nullable public save-mechanic/gate notes, not an "
        "observed save, elapsed-time promise or save-retention PASS.",
        "legacyFields": "saveLocation/windowTitle remain null for unobserved "
        "host save directory/exact window identity. S2 still needs explicit "
        "observed --save-dir ABS and --window-title EXACT.",
        "evidence": "Every research field has per-field sources with URL, date, "
        "platform scope and finding, including attempts behind nulls. "
        "Search-generated summaries alone are not evidence.",
        "launches": "Existing adf8 recipes, COM environment, profile snapshots, "
        "manifest and complete receipts are preserved verbatim from v1. "
        "No status refresh, prefix preparation, game launch or save writes.",
    }
    for row in packet["items"]:
        fields = researched[row["storeId"]]
        row["researchEvidence"] = {}
        for field, detail in fields.items():
            row[field] = detail["value"]
            row["researchEvidence"][field] = {
                key: value for key, value in detail.items() if key != "value"
            }
        path = row["save_path"]
        row["save_path_uses_wgs"] = (
            r"\systemappdata\wgs" in path.lower() if path else None
        )
    packet["publicResearchCounts"] = {
        field: {
            "populated": sum(row[field] is not None for row in packet["items"]),
            "unknown": sum(row[field] is None for row in packet["items"]),
        }
        for field in FIELDS
    }
    return packet


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Compare without writing")
    args = parser.parse_args()
    output = DATA / "s3-ready-packets-v2.json"
    packet = build_packet(load_json(DATA / "s3-ready-packets-v1.json"))
    content = json.dumps(packet, indent=2, ensure_ascii=True) + "\n"
    if args.check:
        if output.read_text() != content:
            raise SystemExit("Published v2 packet differs from the offline research generator")
    else:
        output.write_text(content)
    print(json.dumps(packet["publicResearchCounts"], sort_keys=True))


if __name__ == "__main__":
    main()
