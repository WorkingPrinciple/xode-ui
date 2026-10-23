# SPDX-License-Identifier: GPL-3.0-only
"""v0.2 editable concepts: Apple Games composition, original immersive imagery.

Static SVGs specify layout and glass placement, not real compositor refraction.
NativeGlass.swift is the implementation authority for actual system Liquid Glass.
"""
import base64
from html import escape
import json
from pathlib import Path
from xml.dom import minidom
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TOKENS = json.loads((ROOT / "design" / "tokens.json").read_text(encoding="utf-8"))
C = TOKENS["color"]
OUT = ROOT / "design" / "screens"
ASSETS = ROOT / "design" / "artwork" / "embedded"
used = set()


def rect(x, y, w, h, fill, radius=0, opacity=1, stroke=None):
    border = f' stroke="{stroke}"' if stroke else ""
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}" opacity="{opacity}"{border}/>'


def text(x, y, value, size=18, fill=None, weight=400, anchor="start"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill or C["text"]}" text-anchor="{anchor}">{escape(value)}</text>')


def line(x1, y, x2):
    return f'<path d="M{x1} {y}H{x2}" stroke="{C["separator"]}"/>'


def button(x, y, label, width=180, primary=True, disabled=False):
    return (rect(x, y, width, 42, C["separator"] if disabled else C["accent"] if primary else "#ffffff",
                 21, .9, "#ffffff" if not primary else None)
            + text(x+width/2, y+27, label, 16,
                   C["secondary"] if disabled else "#ffffff" if primary else C["text"], 600, "middle"))


def art(kind, x, y, w, h, uid):
    used.add(kind)
    return (f'<svg x="{x}" y="{y}" width="{w}" height="{h}" viewBox="0 0 2048 1152" '
            'preserveAspectRatio="xMidYMid slice">'
            f'<use href="#asset-{kind}" width="2048" height="1152"/></svg>')


def base():
    return rect(0, 0, 1440, 980, C["background"])


def chrome(active="Library", search=None, search_y=414):
    pieces = []
    for x, fill in [(28, "#fa625a"), (50, "#f5bf50"), (72, "#53bd69")]:
        pieces.append(f'<circle cx="{x}" cy="27" r="6.5" fill="{fill}"/>')
    pieces += [text(99, 34, "Xodus", 16, "#ffffff", 600),
               rect(486, 17, 468, 58, "#132033", 29, .78, "#a6b3c3")]
    for i, tab in enumerate(["Library", "Discover", "Downloads"]):
        x = 493+i*152
        if tab == active:
            pieces.append(rect(x, 24, 150, 44, "#ffffff", 22, .19))
        pieces.append(text(x+75, 52, tab, 17, "#ffffff", 600 if tab == active else 400, "middle"))
    pieces += [f'<circle cx="1365" cy="46" r="25" fill="#132033" opacity=".8"/>',
               text(1365, 53, "F", 18, "#ffffff", 600, "middle"),
               rect(440, 94, 560, 32, "#132033", 16, .86),
               text(720, 115, "Fixture preview. No sign-in, downloads or gameplay.", 14, "#ffffff", anchor="middle")]
    if search is not None:
        pieces += [rect(430, search_y, 580, 46, "#132033", 23, .84, "#a6b3c3"),
                   f'<circle cx="454" cy="{search_y+21}" r="6" fill="none" stroke="#ffffff" stroke-width="1.5"/>',
                   f'<path d="M459 {search_y+26}l5 5" stroke="#ffffff" stroke-width="1.5"/>',
                   text(477, search_y+29, search, 16, "#ffffff")]
    return "".join(pieces)


GAMES = [
    ("Lumen Harbor", "harbor", "Purchased", "Verified (fixture)"),
    ("Orbit Almanac", "orbit", "Subscription access", "Experimental"),
    ("Paper Ridge", "ridge", "Purchased", "Verified (fixture)"),
    ("The Last Signal", "signal", "Purchased", "Unsupported"),
    ("Moss & Meridian", "moss", "No access", "Unknown"),
    ("Tidal Atlas", "tide", "Access unverified", "Experimental")
]


def library():
    s = (base()+art("harbor", 0, 0, 1440, 480, "hero")
         +rect(0, 160, 700, 245, "#081521", opacity=.16)
         +text(58, 242, "Lumen Harbor", 54, "#ffffff", 700)
         +text(58, 287, "A quiet adventure beyond the tide.", 22, "#ffffff")
         +button(58, 319, "Explore fixture", 180, primary=False)
         +text(56, 530, "Continue Playing", 24, weight=700)
         +art("harbor", 56, 552, 60, 60, "continue")
         +text(135, 576, "Lumen Harbor", 19, weight=600)
         +text(135, 603, "Simulate play / Installed fixture", 16, C["secondary"])
         +line(56, 636, 1384)+text(56, 682, "Your Games", 28, weight=700)
         +text(233, 682, "4", 22, C["secondary"])
         +button(1036, 651, "All access", 150, primary=False)
         +button(1204, 651, "Sort by title", 180, primary=False))
    for i, (title, kind, access, compatibility) in enumerate(GAMES[:4]):
        x, y = 56+(i % 3)*452, 720+(i // 3)*120
        s += (art(kind, x, y, 68, 68, f"entry-{i}")
              +text(x+86, y+20, title, 19, weight=600)
              +text(x+86, y+45, access, 16, C["secondary"])
              +text(x+86, y+69, compatibility, 14, C["secondary"])
              +text(x+86, y+92, "Added in demo", 13, C["secondary"])
              +rect(x+366, y+3, 62, 28, C["chrome"], 14)
              +text(x+397, y+22, "View", 14, anchor="middle"))
    return s+chrome(search="Search Library")+text(56, 965, "Original illustrated placeholders. Access and compatibility are independent invented evidence.", 14, C["secondary"])


def discover_browse():
    s = (base()+art("orbit", 0, 0, 1440, 550, "hero")
         +text(58, 302, "Orbit Almanac", 54, "#ffffff", 700)
         +text(58, 348, "Find a new rhythm among the stars.", 22, "#ffffff")
         +button(58, 380, "Explore fixture", 180, primary=False)
         +text(56, 605, "Browse fixture worlds", 26, weight=700))
    for i, (title, kind) in enumerate([("All worlds", "tide"), ("Quiet adventures", "harbor"),
                                       ("Space", "orbit"), ("Puzzles", "ridge")]):
        x = 56+i*338
        s += art(kind, x, 635, 314, 222, f"genre-{i}")
        s += rect(x, 796, 314, 61, "#081521", opacity=.45)
        s += text(x+20, 835, title, 23, "#ffffff", 600)
    return s+chrome("Discover", "Search Discover", 477)+text(56, 922, "Empty-query browse, not fake search results. Catalog discovery does not grant access.", 17, C["secondary"])


def discover_search():
    return (base()+art("orbit", 0, 0, 1440, 315, "backdrop")
            +text(56, 369, 'Search results for "atlas"', 28, weight=700)
            +text(56, 406, "1 catalog fixture. Search stays in Discover.", 18, C["secondary"])
            +art("tide", 56, 439, 440, 280, "result")
            +text(56, 755, "Tidal Atlas", 24, weight=600)
            +text(56, 790, "Access unverified / Experimental fixture", 17, C["secondary"])
            +button(56, 826, "View fixture details", 225)
            +text(572, 490, "A listing is not ownership.", 28, weight=600)
            +text(572, 536, "Use Library to search genuinely entitled titles.", 19, C["secondary"])
            +text(572, 575, "All titles and claims here are invented demonstrations.", 19, C["secondary"])
            +chrome("Discover", "atlas  /  Discover scope", 227))


def detail(blocked=False):
    title, kind = ("The Last Signal", "signal") if blocked else ("Paper Ridge", "ridge")
    s = (base()+art(kind, 0, 0, 1440, 470, "detail")
         +text(58, 344, title, 54, "#ffffff", 700)
         +text(58, 390, "Standard edition / Original fictional world", 21, "#ffffff")
         +text(56, 529, "Four independent questions. One safe decision.", 28, weight=700))
    rows = [("Access", "Purchased"), ("Downloadability", "No eligible PC package" if blocked else "PC package available"),
            ("Compatibility", "Unsupported configuration" if blocked else "Verified (invented evidence)"),
            ("This Mac", "Not installed")]
    for i, (label, value) in enumerate(rows):
        y = 584+i*62
        s += text(56, y, label, 18, C["secondary"])+text(250, y, value, 19)
        s += line(56, y+23, 775)
    s += text(56, 882, "Fixed fixture time / fixture OS / arm64 / fixture-xodus-pair-1", 15, C["secondary"])
    s += text(56, 914, "Product, edition and package identities remain distinct.", 15, C["secondary"])
    if blocked:
        s += (text(849, 590, "Cannot install this fixture", 26, weight=600)
              +text(849, 637, "Purchase does not establish downloadability", 18, C["secondary"])
              +text(849, 666, "or support for this configuration.", 18, C["secondary"])
              +button(849, 717, "Install unavailable", 250, disabled=True))
    else:
        s += (text(849, 590, "Review before you begin", 26, weight=600)
              +text(849, 637, "4 GB download / 8 GB expanded", 18, C["secondary"])
              +text(849, 675, "Exact runtime pair required.", 18, C["secondary"])
              +button(849, 717, "Review fixture install", 256))
    return s+chrome()


def install():
    s = detail()+rect(0, 0, 1440, 980, "#071221", opacity=.4)+rect(355, 181, 730, 661, "#ffffff", 24, .97)
    s += text(397, 222, "Fixture preview. No files will be written.", 15, C["secondary"])
    s += text(397, 276, "Review fixture install", 34, weight=700)
    s += text(397, 314, "Paper Ridge / Standard edition", 20, weight=600)
    for i, (label, value) in enumerate([("Download", "4 GB"), ("Expanded game", "8 GB"), ("Staging", "4 GB"),
                                      ("Safety reserve", "2 GB"), ("Required free", "14 GB"),
                                      ("Available (simulated)", "120 GB"), ("Destination", "Demo storage / Games"),
                                      ("Package version", "1.0-demo"), ("Runtime pair", "fixture-xodus-pair-1")]):
        y = 372+i*34
        s += text(397, y, label, 17, C["secondary"])+text(715, y, value, 17)
    return (s+text(397, 712, "No download or install is performed. This is a simulated plan.", 16, C["secondary"])
            +button(397, 767, "Cancel", 110, primary=False)+button(833, 767, "Simulate install", 210))


def downloads(error=False):
    s = (base()+art("orbit", 0, 0, 1440, 270, "header")
         +text(56, 220, "Downloads", 42, "#ffffff", 700)
         +text(56, 314, "Simulated queue. Advance steps manually; no bytes are transferred.", 18, C["secondary"]))
    for i, (title, kind, phase, fraction) in enumerate([
        ("Paper Ridge", "ridge", "Failed - simulated" if error else "Verifying - simulated", .65),
        ("Orbit Almanac", "orbit", "Queued - simulated", 0)
    ]):
        y = 357+i*238
        s += (art(kind, 56, y, 112, 90, f"job-{i}")+text(194, y+26, title, 24, weight=600)
              +text(194, y+62, phase, 18, C["secondary"])
              +text(1384, y+30, f"{int(fraction*100)}%", 24, weight=600, anchor="end")
              +rect(194, y+88, 1190, 5, C["separator"], 2)
              +rect(194, y+88, max(1,1190*fraction), 5, C["accent"], 2))
        if error and i == 0:
            s += text(194, y+126, "NETWORK_UNAVAILABLE (fixture). No live service or files involved.", 17, C["warningText"])
            s += button(194, y+151, "Simulate retry", 178)
        else:
            s += button(194, y+123, "Simulate next step", 212)+button(425, y+123, "Simulate cancel", 186, primary=False)
        s += line(56, y+210, 1384)
    return s+chrome("Downloads")+text(56, 906, "Production jobs require durable recovery. This fixture queue resets on relaunch.", 18, C["secondary"])


def onboarding():
    return (base()+art("harbor", 0, 0, 660, 980, "welcome")
            +text(56, 780, "Your games.", 46, "#ffffff", 700)
            +text(56, 835, "A more native way home.", 40, "#ffffff", 700)
            +text(738, 267, "A carefully paired journey.", 34, weight=700)
            +text(738, 326, "Legitimate PC access. Native Mac controls.", 20, C["secondary"])
            +text(738, 366, "No Terminal or arbitrary runtime selection.", 20, C["secondary"])
            +text(738, 446, "This preview never opens Microsoft sign-in.", 19, C["secondary"])
            +text(738, 486, "Games, access and compatibility are invented.", 19, C["secondary"])
            +text(738, 576, "Sign-in cancelled (fixture)", 24, weight=600)
            +text(738, 620, "No credentials created. Retry or close safely.", 18, C["secondary"])
            +button(738, 691, "Simulate connection", 240)
            +button(997, 691, "Close preview flow", 228, primary=False)
            +text(738, 813, "GPL-3.0-only app. API/redistribution remain gated.", 16, C["secondary"])
            +rect(745, 95, 620, 36, "#ffffff", 18, .9)
            +text(1055, 119, "Fixture preview. No real sign-in, downloads or gameplay.", 14, anchor="middle"))


def write(name, generate):
    used.clear()
    body = generate()
    images = []
    for kind in sorted(used):
        encoded = base64.b64encode((ASSETS / f"{kind}.jpg").read_bytes()).decode("ascii")
        images.append(f'<image id="asset-{kind}" width="2048" height="1152" href="data:image/jpeg;base64,{encoded}"/>')
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="980" viewBox="0 0 1440 980">'
           f'<title>Xodus v0.2 {escape(name)} fixture concept</title>'
           '<desc>Original illustrated placeholders. Editable text/vector layout. Static glass placement is not proof of native refraction.</desc>'
           f'<defs>{"".join(images)}</defs><g font-family="{TOKENS["type"]["family"]}">{body}</g></svg>')
    ET.fromstring(svg)
    if len(svg.encode("utf-8")) > 10_000_000:
        raise ValueError(f"{name} exceeds the 10 MB upload limit")
    (OUT / f"{name}.svg").write_text(minidom.parseString(svg).toprettyxml(indent="  "), encoding="utf-8")
    print(f"design/screens/{name}.svg")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, generate in [
        ("library", library), ("discover-browse", discover_browse), ("discover-search", discover_search),
        ("game-detail", detail), ("install-sheet", install), ("downloads", downloads),
        ("onboarding-cancelled", onboarding), ("blocked", lambda: detail(True)),
        ("download-error", lambda: downloads(True))
    ]:
        write(name, generate)
