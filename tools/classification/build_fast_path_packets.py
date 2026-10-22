#!/usr/bin/env python3
"""Publish cited human test scripts offline; optional triage capture is read-only."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess

from inspect_queue import DATA, load_json


DATE = "2026-10-22"
FIELDS = (
    "logo_skip", "intro_skip", "tutorial_skip", "title_to_gameplay",
    "keyboard_controls", "gamepad_alternative", "save_trigger",
    "expected_minutes_to_save", "quit", "relaunch_indicator",
)
PCGW = "https://www.pcgamingwiki.com/wiki/"
SOURCES = {
    "dishonored-manual": (
        "https://cdn.akamai.steamstatic.com/steam/apps/205100/manuals/dishonored-gfw-manual-v15.pdf?t=1447355207",
        "Official original PC manual, pages 1, 5-6; Windows Store Definitive is a proxy",
        "New Game, Continue, Load, non-combat manual saving and PC controls. "
        "PDF text inspected with macOS PDFKit; not an exact Store menu observation.",
    ),
    "dishonored-opening": (
        "https://www.trueachievements.com/game/Dishonored/walkthrough/3",
        "Original Xbox 360 gameplay walkthrough, proxy for Definitive PC",
        "Control begins after opening scene; Emily's hide-and-seek tutorial is optional.",
    ),
    "skyrim-controls": (
        "https://en.uesp.net/w/index.php?title=Skyrim:Controls&action=raw",
        "UESP Skyrim PC/Xbox controls and menus; verify Special Edition Store prompts",
        "WASD, mouse, Space, E, F5, F9, Journal/System, New/Load/Continue documented.",
    ),
    "skyrim-opening": (
        "https://en.uesp.net/wiki/Skyrim:Unbound",
        "UESP base Skyrim quest walkthrough; Special Edition story proxy",
        "Cart ride, character naming and dragon attack precede escape movement.",
    ),
    "stardew-start": (
        "https://stardewvalleywiki.com/Getting_Started",
        "Official wiki attempt, HTTP 403",
        "No body admitted; exact character-creation, keyboard and intro-skip steps remain unknown.",
    ),
    "limbo-controls": (
        "https://pcgamecontrols.fandom.com/wiki/Limbo",
        "Community PC controls article, explicitly Steam layout",
        "Arrow movement and Ctrl object interaction; autosave and controller support. "
        "Does not establish title-screen sequence, jump key or gamepad button map.",
    ),
    "limbo-opening": (
        "https://www.trueachievements.com/game/LIMBO/walkthrough/3",
        "Xbox LIMBO story walkthrough",
        "Opening forest, then rightward route to cart/platform/rope and boat; "
        "chapter boundary is not proof of earliest disk-save commit.",
    ),
    "kcd-opening": (
        "https://www.trueachievements.com/game/Kingdom-Come-Deliverance/walkthrough/3",
        "First-game Xbox walkthrough, Standard mode",
        "Opening mother conversation ends in an autosave and control of Henry in Skalitz.",
    ),
    "kcd-saving": (
        "https://www.trueachievements.com/game/Kingdom-Come-Deliverance/walkthrough/2",
        "First-game Xbox controls/save guide, not KCD II",
        "Standard-mode autosaves and Save & exit to menu; manual save consumes "
        "Saviour Schnapps; controller movement/interact documented.",
    ),
    "hogwarts-skip": (
        "https://www.destructoid.com/can-you-skip-cutscenes-in-hogwarts-legacy-answered/",
        "PC and console cutscene guide",
        "Hold right mouse/Y when skip prompt appears, including opening; "
        "interactive cave potion/look/movement tutorial is not skippable.",
    ),
    "hogwarts-save": (
        "https://gamerant.com/hogwarts-legacy-how-to-save-manual/",
        "Cross-platform gameplay save guide, updated 2023-05-05",
        "Pause Save/Load and Exit tab, manual saves outside restricted scenes; "
        "autosave icon must finish. Earliest tutorial save/time not established.",
    ),
    "hogwarts-slots": (
        "https://gamewith.net/hogwarts-legacy/article/show/37935",
        "Cross-platform illustrated menu guide",
        "Menu > Settings > Save Game, ten manual/five autosave slots per character. "
        "Do not delete characters to create a test slot.",
    ),
    "ffiv-identity": (
        PCGW + "Final_Fantasy_IV?action=raw",
        "PCGamingWiki 2D Pixel Remaster, Steam 1173800 / Store 9N8C07SS8C9D",
        "Mouse menu, keyboard/controller remapping and XInput supported; exact "
        "opening keys, earliest save and relaunch card not specified. Not 3D remake.",
    ),
    "ffiv-guide-attempt": (
        "https://www.trueachievements.com/game/Final-Fantasy-IV/walkthrough/2",
        "Walkthrough candidate redirected to site homepage",
        "No title walkthrough admitted. General Final Fantasy or 3D remake "
        "quicksave deletion claims are not Pixel Remaster evidence.",
    ),
    "ffiv-guide-edition-rejected": (
        "https://gamefaqs.gamespot.com/switch/402303-final-fantasy-iv-pixel-remaster/faqs/78175",
        "Pixel Remaster landing URL serving a Guide and Walkthrough (SNES)",
        "Returned heading explicitly labels the walkthrough SNES. Not admitted "
        "for Pixel Remaster keyboard, quicksave or autosave semantics.",
    ),
    "ffiv-rpgsite-rejected": (
        "https://www.rpgsite.net/feature/11606-final-fantasy-iv-pixel-remaster-walkthrough-guide-and-boss-strategies",
        "Search-suggested URL redirected to Dodgeball Academia review",
        "Wrong-title redirect; no Final Fantasy instruction admitted.",
    ),
    "replaced-skip-risk": (
        "https://www.kakuchopurei.com/2026/04/replaced-review-kkp/",
        "Publisher-supplied PC review, April 2026",
        "Reviewer experienced cutscene-skip softlocks and checkpoint restarts. "
        "Build-specific risk, not proof the installed version retains the bug.",
    ),
    "wasteland-official": (
        "https://news.xbox.com/en-us/2020/02/25/wasteland-remastered-survival-guide/",
        "Official Xbox Wire Windows 10/Xbox survival guide",
        "Premade Ranger team available; H/Y opens manual from character pane. "
        "Esc advances world time, so do not assume Esc is Pause.",
    ),
    "wasteland-menu": (
        "https://www.trueachievements.com/game/Wasteland/walkthrough/2",
        "Remastered Xbox/PC walkthrough",
        "Pause command exposes save/load/quit. Exact keyboard Pause shortcut and "
        "earliest tutorial restriction not identified.",
    ),
    "subnautica-modes": (
        "https://wiki.subnautica.com/sn2/Game_Modes",
        "Subnautica 2 community wiki, current Early Access",
        "Survival and Creative chosen per new save; Creative removes survival "
        "requirements. No exact start-menu input route or first-save time.",
    ),
    "subnautica-controls-attempt": (
        "https://wiki.subnautica.com/sn2/Controls",
        "Subnautica 2 controls-page attempt, HTTP 404",
        "No current title-specific keyboard/gamepad bindings admitted; "
        "do not substitute Subnautica 1 or Below Zero controls.",
    ),
    "beast-controls": (
        "https://www.shacknews.com/article/150234/beast-of-reincarnation-controls-pc-keybindings",
        "PC/Xbox controls guide",
        "WASD/left stick movement, Space/A jump or interact; exact "
        "title-screen path and earliest save gate are not specified.",
    ),
    "keeper-controls": (
        "https://gameaccess.info/keeper-controls/",
        "SpecialEffect GameAccess accessibility controls article, PC/Xbox",
        "WASD/left stick movement, mouse/right stick lamp; Left Shift/RT "
        "focus light, Space/A action, left click/X bird. Opening teaches movement.",
    ),
    "keeper-patch-attempt": (
        "https://www.doublefine.com/games/support/october-update-version-1213620-keeper",
        "Official patch-note attempt",
        "Web extraction returned page boilerplate; direct request HTTP 403. "
        "No save checkpoint, skip or exact menu instructions admitted.",
    ),
    "mixtape-patch": (
        "https://www.vice.com/en/article/mixtape-makes-big-improvement-in-new-patch/",
        "Reported developer 1.1 patch notes, explicitly Windows Store included",
        "Chapter Select gains Play from Outro in version 1.1. Installed version/"
        "chapter unlock not verified; not a fresh-save tutorial bypass.",
    ),
    "forever-review": (
        "https://gamingtrend.com/reviews/forever-ago-review/",
        "Publisher-supplied PS5 review, cross-platform mechanic proxy",
        "Checkpoint-only autosaves; New Game replaces the save; chapter select "
        "after completion. Exact PC keys and first checkpoint unspecified.",
    ),
    "bluey-official": (
        "https://www.gameloft.com/newsroom/blueys-happy-snaps-video-game-gameloft-2026",
        "Official Gameloft title announcement, not Bluey: The Videogame",
        "Photography/scrapbook and local co-op described. No key map, save "
        "gate, title sequence or quit/relaunch labels supplied.",
    ),
    "oblivion-manual": (
        "https://archive.org/download/obliv_goty_pc_man-v2/obliv_goty_pc_man-v2_djvu.txt",
        "Bethesda original Oblivion GOTY PC manual, pages 3-4, archival OCR",
        "New starts a new game; Continue most recent save; Load specific saves; "
        "in-game Save/ Quit to Start, main-menu Exit. F5/F9 quicksave/load. "
        "Not Oblivion Remastered.",
    ),
    "deathloop-initial-save": (
        PCGW + "Deathloop?action=raw",
        "Microsoft Store/Game Pass save-creation instruction, not Steam controls",
        "Transfer guide explicitly says to let the first cutscene play through "
        "to create a Store save file. No file copying/editing is proposed here.",
    ),
}


def citation(key):
    url, scope, finding = SOURCES[key]
    return {"url": url, "checkedAt": DATE, "scope": scope, "finding": finding}


def field(value, *keys, reason=None):
    return {
        "value": value,
        "status": "public-expectation" if value is not None else "unknown",
        "sources": [citation(key) for key in keys],
        "limitation": reason,
    }


def fast_paths(base):
    items = {row["storeId"]: row for row in base["items"]}
    scripts = {}
    for store_id in base["s3OrderIncludingRequiredHogwarts"]:
        row = items[store_id]
        source = copy.deepcopy(row["compatibilityEvidence"]["appleGamingWiki"])
        fallback = {
            "url": source["url"], "checkedAt": source["checkedAt"],
            "scope": "Inspected public compatibility article, not a control manual",
            "finding": "Exact menu/input/save timing not established by the "
            "compatibility rating. No standard-engine/default-key inference.",
        }
        if row.get("researchEvidence"):
            public = row["researchEvidence"]["tutorial_save_gate"]["sources"][0]
            fallback = {
                **copy.deepcopy(public),
                "finding": "This previously inspected title-specific source "
                "did not establish the exact input/skip/menu/timing phase. "
                "Confirmed save mechanics are cited separately below.",
            }
        phases = {
            key: {
                "value": None, "status": "unknown", "sources": [fallback],
                "limitation": "No confirmed title/edition-specific instruction.",
            }
            for key in FIELDS
        }
        for new_key, old_key in (("save_trigger", "tutorial_save_gate"), ("quit", "quit")):
            if row.get("researchEvidence", {}).get(old_key):
                phases[new_key] = {
                    "value": row[old_key],
                    **copy.deepcopy(row["researchEvidence"][old_key]),
                    "limitation": "Inherited v2 public mechanic; earliest gate/"
                    "Store behavior and elapsed time remain unobserved.",
                }
        scripts[store_id] = {
            "storeId": store_id, "title": row["title"],
            "order": len(scripts) + 1, "phases": phases,
            "warnings": [],
        }

    def set_fields(store_id, **updates):
        scripts[store_id]["phases"].update(updates)

    set_fields(
        "9P1N07XDL1D4",
        title_to_gameplay=field(
            "New Game; after the opening scene Corvo becomes controllable. "
            "Stop at first safe non-combat movement rather than completing "
            "the prison escape. Exact menu-confirm/difficulty keystrokes unknown.",
            "dishonored-manual", "dishonored-opening"),
        tutorial_skip=field(
            "Emily's hide-and-seek is optional; decline it if offered. "
            "No confirmed whole-prologue skip.", "dishonored-opening"),
        keyboard_controls=field(
            "WASD move, mouse look, Space jump, F use. "
            "Menu navigation/skip key not established by inspected manual text.",
            "dishonored-manual"),
        save_trigger=field(
            "Use a new manual save as soon as control is available outside "
            "combat. Official manual allows manual saving when not fighting; "
            "if disabled in opening, earliest enabled point remains unknown.",
            "dishonored-manual"),
        relaunch_indicator=field(
            "Main menu Load selects a specific save; Continue resumes the "
            "last saved point. Record the test save and reload it, then compare "
            "the position with the pre-quit screenshot. Exact card fields unknown.",
            "dishonored-manual"),
    )
    set_fields(
        "9P03JGQ4S1GC",
        title_to_gameplay=field(
            "Main menu New; follow the cart sequence, accept/name a character "
            "in an unused test slot and follow the dragon-attack escape until "
            "movement is enabled. Exact confirm sequence unknown.",
            "skyrim-controls", "skyrim-opening"),
        keyboard_controls=field(
            "WASD move, mouse look, Space jump, E use; J or Esc opens Journal. "
            "F5 writes QUICK and F9 loads it. Do not overwrite an owner's quicksave.",
            "skyrim-controls"),
        gamepad_alternative=field(
            "Left stick move, right stick look, Y jump, A use, Start Journal "
            "(published Xbox layout; verify Store prompts).", "skyrim-controls"),
        quit=field(
            "J/Esc > Journal > System > Quit returns to main menu; manual-save "
            "first. Exact Store desktop-exit submenu is unconfirmed.",
            "skyrim-controls"),
        relaunch_indicator=field(
            "Load lists previously saved games; Continue selects the latest. "
            "Select the newly recorded test save and compare loaded state. "
            "Exact Special Edition slot-card fields are not confirmed.",
            "skyrim-controls"),
    )
    set_fields(
        "9MWR1NC6VQ6L",
        intro_skip=field(None, "stardew-start",
                         reason="Wiki blocked; search summaries/mod instructions not admitted."),
        title_to_gameplay=field(None, "stardew-start"),
        keyboard_controls=field(None, "stardew-start"),
        save_trigger={
            **scripts["9MWR1NC6VQ6L"]["phases"]["save_trigger"],
            "limitation": "Research-based optimization: after testing movement, "
            "return to bed immediately rather than completing farm chores. "
            "Earliest allowed bedtime/day and duration not measured.",
        },
    )
    set_fields(
        "9PNG83MDD6SH",
        keyboard_controls=field(
            "Arrow keys move; Ctrl manipulates objects. Jump key not "
            "established by this source; use the displayed prompt.",
            "limbo-controls"),
        title_to_gameplay=field(
            "Opening story begins in the forest. Once controllable, move right; "
            "the next section introduces a cart/platform/rope and then a boat. "
            "Exact title-screen activation is unknown.", "limbo-opening"),
        save_trigger=field(
            "Autosave is reported. Advance beyond the starting forest toward "
            "the next puzzle/checkpoint before attempting retention; earliest "
            "persistent checkpoint and visible save indicator unknown.",
            "limbo-controls", "limbo-opening"),
    )
    set_fields(
        "9P3T7HVKM6D0",
        title_to_gameplay=field(
            "Use Standard mode for the cited autosave behavior. After the "
            "opening scene, finish Henry's conversation with his mother "
            "(dialogue choices may be selected normally). Ending that dialogue "
            "autosaves and releases control in Skalitz. Exact PC menu keys unknown.",
            "kcd-opening"),
        gamepad_alternative=field(
            "Left stick move, right stick look; A interacts; Start opens menu. "
            "Use current dialogue prompts to exit mother's conversation.",
            "kcd-saving", "kcd-opening"),
        save_trigger=field(
            "First documented gate: finish the opening mother conversation on "
            "Standard and wait for autosave notification. No need to reach "
            "Awakening, buy Schnapps or finish the prologue for this gate. "
            "Pause > Save & exit to menu is a separate save mechanism.",
            "kcd-opening", "kcd-saving"),
    )
    set_fields(
        "9MT5NJ5W7B8Z",
        intro_skip=field(
            "Show the skip prompt, then hold right mouse on PC or Y on Xbox. "
            "Works on skippable opening scenes, not every scene.",
            "hogwarts-skip"),
        tutorial_skip=field(
            "The interactive cave potion/look/movement sequence cannot be "
            "skipped by the cutscene button; complete its on-screen prompts.",
            "hogwarts-skip"),
        title_to_gameplay=field(
            "Opening follows accessibility/performance setup; use only displayed "
            "prompts for remaining character/menu choices (exact sequence "
            "unknown). After skippable opening scenes, the cave teaches potion "
            "use and look/movement; stop once those controls can be exercised.",
            "hogwarts-skip"),
        save_trigger=field(
            "Pause > Save/Load and Exit (or Menu > Settings > Save Game in the "
            "illustrated guide), choose an unused manual slot when enabled. "
            "Wait for autosave icon to finish if relying on autosave. Earliest "
            "opening unlock is unconfirmed; do not promise a pre-Hogwarts save.",
            "hogwarts-save", "hogwarts-slots"),
        quit=field(
            "Pause > Save/Load and Exit > exit to main menu, after saving. "
            "Exact desktop-exit chain is unconfirmed.", "hogwarts-save"),
        relaunch_indicator=field(
            "Character selection holds up to four characters; each has manual "
            "and autosave slots. Select the existing test character/save rather "
            "than New Character. Exact slot-card fields/key sequence unknown.",
            "hogwarts-slots", "hogwarts-save"),
    )
    scripts["9MT5NJ5W7B8Z"]["warnings"].append(
        "Required title, but last S3 evidence is pre-window FAIL with retriable "
        "COM work. This public script neither clears that hold nor supplies "
        "a current launch recipe/complete receipt."
    )
    set_fields(
        "9N8C07SS8C9D",
        title_to_gameplay=field(None, "ffiv-identity", "ffiv-guide-attempt"),
        keyboard_controls=field(None, "ffiv-identity",
                                reason="Remapping/mouse menus confirmed, not default key map."),
        gamepad_alternative=field(None, "ffiv-identity",
                                 reason="XInput supported; exact button map unconfirmed."),
        save_trigger=field(None, "ffiv-identity", "ffiv-guide-attempt",
                           "ffiv-guide-edition-rejected", "ffiv-rpgsite-rejected",
                           reason="Do not borrow FF1/3D remake temporary-quicksave semantics."),
    )
    set_fields(
        "9NV3L234VGXD",
        intro_skip=field(None, "replaced-skip-risk",
                         reason="Exact skip key unknown; avoid skip while qualifying saves."),
        tutorial_skip=field(None, "replaced-skip-risk",
                            reason="Cutscene skips caused softlocks in launch PC review."),
    )
    scripts["9NV3L234VGXD"]["warnings"].append(
        "Let cutscenes run: a reviewed PC build softlocked when skipped. "
        "Do not turn a skip-induced softlock into an engine failure verdict."
    )
    set_fields(
        "9NGH1FK0RJGL",
        title_to_gameplay=field(
            "Use the supplied premade Ranger team instead of rolling custom "
            "characters; the official guide confirms it is available at Ranger "
            "Center. Exact title/menu input chain unknown.",
            "wasteland-official"),
        save_trigger=field(
            "Open the displayed Pause command and select save into a new slot. "
            "The walkthrough documents save/load there; earliest availability/"
            "shortcut unknown. Do not assume Esc: official guide says it passes time.",
            "wasteland-menu", "wasteland-official"),
        quit=field(
            "Pause command > quit after explicit save. Exact confirm and "
            "desktop-versus-menu target unknown.", "wasteland-menu"),
        relaunch_indicator=field(
            "Use the documented load option to locate the newly created test "
            "save; exact card fields/title-screen input path unknown.",
            "wasteland-menu"),
    )
    set_fields(
        "9PJPCB188SVG",
        tutorial_skip=field(None, "subnautica-modes",
                            reason="Creative removes survival needs, not a verified tutorial skip."),
        keyboard_controls=field(None, "subnautica-controls-attempt"),
        gamepad_alternative=field(None, "subnautica-controls-attempt"),
    )
    original = scripts["9PJPCB188SVG"]["phases"]["save_trigger"]
    scripts["9PJPCB188SVG"]["phases"]["relaunch_indicator"] = {
        **copy.deepcopy(original),
        "value": "Public Early Access thread distinguishes Load Game manual "
        "save selection from latest-save Continue. Select the intended test "
        "manual save, not an assumed Continue target. Exact card fields unknown.",
    }
    set_fields(
        "9NXWSWBM4H6T",
        keyboard_controls=field(
            "WASD movement; Space jumps/interacts. Title/menu confirm and "
            "cutscene-skip keys unconfirmed.", "beast-controls"),
        gamepad_alternative=field(
            "Xbox left stick movement and A jump/interact; verify on-screen "
            "menu prompts rather than assuming a confirm path.", "beast-controls"),
    )
    scripts["9NXWSWBM4H6T"]["phases"]["save_trigger"]["limitation"] = (
        "Prefer documented Menu > Settings > Other > Return to Title quick "
        "autosave when available, instead of searching for a camp. Earliest "
        "menu unlock and elapsed time remain unknown."
    )
    set_fields(
        "9NCJWHHMVHR0",
        keyboard_controls=field(
            "WASD move, mouse aim lamp, Left Shift focus, Space action, left "
            "click bird, X recall bird. Movement is taught as lighthouse awakens.",
            "keeper-controls"),
        gamepad_alternative=field(
            "Left stick move, right stick lamp, RT focus, A action, X bird, "
            "B recall. No title-screen confirm sequence established.",
            "keeper-controls"),
        save_trigger=field(None, "keeper-patch-attempt",
                           reason="Do not infer safe-to-quit autosave from no health/failure states."),
    )
    set_fields(
        "9NH0MSG29X6L",
        tutorial_skip=field(None, "mixtape-patch",
                            reason="1.1 Chapter Select > Play from Outro is a replay "
                            "feature, not a confirmed fresh-save bypass."),
        relaunch_indicator=field(None, "mixtape-patch",
                                reason="Chapter Select exists in 1.1; no first-save "
                                "unlock or Continue label established."),
    )
    set_fields(
        "9NFB47H2SDRX",
        relaunch_indicator=field(None, "forever-review",
                                reason="Chapter select is completion-gated; exact "
                                "initial Continue/slot indicator unknown."),
    )
    scripts["9NFB47H2SDRX"]["warnings"].append(
        "Do not select New Game on relaunch: public review says it overwrites "
        "the only current save. Confirm existing-progress route on-screen."
    )
    set_fields(
        "9P2J5D12GJL5",
        title_to_gameplay=field(
            "Main menu New starts a new game. Exact character-creation/intro "
            "input sequence before free control is not transcribed or confirmed.",
            "oblivion-manual"),
        keyboard_controls=field(
            "F5 quicksave and F9 quickload are documented. Prefer a new named "
            "manual slot if an existing QUICK slot may contain owner progress.",
            "oblivion-manual"),
        relaunch_indicator=field(
            "Main menu Load opens previous saves; Continue selects the most "
            "recent. Select the recorded test save and verify its loaded state. "
            "Exact slot-card fields are not specified in the manual.",
            "oblivion-manual"),
    )
    set_fields(
        "9P5Z4530318L",
        intro_skip=field(
            "Do not skip the first cutscene: the Store-specific guide requires "
            "letting it finish to create an initial save file. This is not yet "
            "proof that controllable-gameplay progress survives relaunch.",
            "deathloop-initial-save",
            reason="Exact skip key unconfirmed; no file/logo edits or transfer "
            "steps are part of this test."),
    )
    for key in FIELDS:
        scripts["9NQVHHW88XW9"]["phases"][key] = field(
            None, "bluey-official",
            reason="Official title source gives gameplay premise, not tested "
            "controls/menu/save instructions; unrelated Bluey game not substituted.",
        )
    return list(scripts.values())


TRIAGE_TITLES = {
    "9PLH7R84GJWP": ("WellDweller-Xbox", "conditional-after-changed-profile-retest",
                      "New profiles passed probes; keep payload until actual retest."),
    "9NGLST31DG26": ("AGameAboutDiggingAHole-Xbox", "conditional-after-runtime-retest",
                      "Valid COM failure, still retriable; very small space benefit."),
    "9PK087LNGJC5": ("Balatro-Xbox", "conditional-after-diagnosis",
                      "Exit0/no window undiagnosed; tiny space benefit, not permanent incompatibility."),
    "9P4NV23Q6QC2": ("AbioticFactor-Xbox", "conditional-after-targeted-STA-retest",
                      "S2 has specifically changed STA1 retest queued; no removal now."),
    "9MT5NJ5W7B8Z": ("HogwartsLegacy-Xbox", "hold-required-title",
                      "Largest payload, but explicitly required and COM candidate work remains. Retain."),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def capture_triage(source_path):
    raw = source_path.read_bytes()
    evidence = json.loads(raw)
    games = {row["productId"]: row for row in evidence["games"]}
    game_root = Path.home() / "Games/Xodus"
    if not game_root.is_dir():
        raise ValueError("Known game root unavailable; no fallback measurements")
    rows = []
    for store_id, (directory, disposition, hold) in TRIAGE_TITLES.items():
        game = games[store_id]
        if game["verdict"] not in {"FAIL", "BLOCKED"}:
            raise ValueError(f"{store_id}: verdict changed; review before recapturing")
        root = game_root / directory
        if not root.is_dir() or root.is_symlink():
            raise ValueError(f"Expected real installed payload directory: {root}")
        result = subprocess.run(
            ["/usr/bin/du", "-sk", str(root)], check=True, capture_output=True, text=True,
        )
        rows.append({
            "storeId": store_id, "title": game["title"], "gameRoot": str(root),
            "allocatedKiB": int(result.stdout.split()[0]),
            "disposition": disposition, "hold": hold,
            "eligibleForDeletionNow": False,
            "s3Evidence": {key: game.get(key) for key in
                           ("verdict", "scope", "blocker", "runId", "owner")},
        })
    disk = os.statvfs(game_root)
    write_json(DATA / "uninstall-proposals-v1.json", {
        "schemaVersion": 1, "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source": {
            "path": str(source_path), "sha256": hashlib.sha256(raw).hexdigest(),
            "updatedAt": evidence["updatedAt"],
            "stablePublishedCopy": str(Path.home() / "Library/Application Support/"
                                       "Ode to X/Evidence/tried-games.json"),
        },
        "workingAdmission": evidence["workingAdmission"],
        "currentFreeBytes": disk.f_bavail * disk.f_frsize,
        "deletionsAuthorized": False, "deletionsPerformed": 0,
        "permanentUninstallRecommendations": [],
        "proposedOrder": "If owners abandon retests, review Well, Digging and "
        "Balatro first; Abiotic only after S2's targeted test. Hogwarts remains "
        "held as required, not recommended. All require new owner approval.",
        "measurementScope": "du -sk on exact five game payload roots only; "
        "allocated accounting is not guaranteed reclaimable APFS space. "
        "No prefix/save/log removal or process termination.",
        "protected": [
            "All prefixes, private saves, WGS/file containers and logs",
            "HK live app prefix and game payload; not a renderer failure",
            "NMS payload, immutable snapshot, accepted recipes",
            "Minecraft native/launcher data and saves",
            "Fallout launcher-only/no-input and Skyrim/other UNTESTED titles",
            "Hades II gameplay pass awaiting save; not a failed payload",
        ],
        "candidates": rows,
    })


def build():
    base_path = DATA / "s3-ready-packets-v3.json"
    base = load_json(base_path)
    result = copy.deepcopy(base)
    result["schemaVersion"] = 4
    result["baseV3"] = {"path": base_path.name, "sha256": sha(base_path)}
    result["fastPathCheckedAt"] = DATE
    result["fastPathContract"] = {
        "format": "Per-title HUMAN test scripts, not executable input automation",
        "readOnlyResearch": True, "launchesPerformed": 0,
        "inputPreference": "Keyboard/mouse first where cited; gamepad alternate "
        "only where documented. Exact unknown keys/labels stay null. Never send "
        "a guessed key to an owner game or another title's focused window.",
        "scope": "Public PC/console mechanics are expectations, not Xbox/"
        "Wine observations. Menus/localization/version may differ.",
        "timing": "All expected_minutes_to_save values null: no inspected "
        "source measures this exact first-save path. Chapter length is not "
        "first-save latency; S3 records actual timings, not inferred estimates.",
        "permission": "Research does not authorize launch, new character/save "
        "overwrite, mods, console commands, file/logo edits or tutorial hacks.",
        "retention": "A Continue label or slot alone is insufficient. Record "
        "pre-quit scene and save state; normal quit; fresh launch; load the "
        "intended test save and compare scene/progress. S2 file evidence is "
        "complementary, not a substitute. Do not claim cloud sync.",
        "unknownHandling": "Each phase carries cited finding/attempt. Null "
        "means unknown, not unsupported or safe to skip. A partial route states "
        "which exact inputs/gates remain unknown; S3 observes on-screen prompts.",
        "inherited": "All v3 identities, recipes/env, status receipts, ranking, "
        "save paths and constraints remain unchanged. Hogwarts still needs "
        "current readiness plus an approved working recipe.",
    }
    result["fastPaths"] = fast_paths(base)
    triage_path = DATA / "uninstall-proposals-v1.json"
    result["uninstallReview"] = {
        "path": triage_path.name, "sha256": sha(triage_path),
        **load_json(triage_path),
    }
    triage = result["uninstallReview"]
    queue = {row["storeId"]: row for row in base["items"]}
    nonrequired = sum(
        row["allocatedKiB"] * 1024 for row in triage["candidates"]
        if row["disposition"] != "hold-required-title"
    )
    triage["spaceComparison"] = {
        "nonRequiredCandidateAllocatedBytes": nonrequired,
        "note": "Compare the four non-required payloads with each target's "
        "deficit below. This is allocated accounting, not promised reclaimed "
        "space or an automatic uninstall plan. Actual free-space delta, staging "
        "margin and S3 backlog must be rechecked after any separate approval.",
        "targets": [
            {
                "storeId": store_id, "title": queue[store_id]["title"],
                "catalogueDownloadBytes": queue[store_id]["downloadSizeBytes"],
                "minimumExtraBytesBeforeMargin": max(
                    0, 150 * 2**30 + queue[store_id]["downloadSizeBytes"]
                    - triage["currentFreeBytes"],
                ),
                "nonRequiredCandidatesCouldCoverBeforeMargin": (
                    triage["currentFreeBytes"] + nonrequired
                    >= 150 * 2**30 + queue[store_id]["downloadSizeBytes"]
                ),
                "source": queue[store_id]["downloadSizeEvidence"],
            }
            for store_id in ("9NJCVGS6T30K", "9P861V1542BL")
        ],
    }
    return result


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--capture-triage", type=Path,
                        help="Explicit S3 JSON snapshot; reads exact payload du/free space only")
    args = parser.parse_args()
    if args.check and args.capture_triage:
        parser.error("--check must remain offline and cannot capture triage")
    if args.capture_triage:
        capture_triage(args.capture_triage)
    packet = build()
    output = DATA / "s3-ready-packets-v4.json"
    if args.check:
        if load_json(output) != packet:
            raise SystemExit("Published v4 differs from frozen sources/generator")
    else:
        write_json(output, packet)
    for script in packet["fastPaths"]:
        populated = sum(value["value"] is not None for value in script["phases"].values())
        print(script["order"], script["title"], f"{populated}/{len(FIELDS)} cited phases")


if __name__ == "__main__":
    main()
