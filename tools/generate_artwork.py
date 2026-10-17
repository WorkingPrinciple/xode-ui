# SPDX-License-Identifier: GPL-3.0-only
"""Author six distinct immersive illustrated worlds without external assets."""
from pathlib import Path
import math
import random
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "design" / "artwork"
W, H = 1600, 900


def path(d, fill, **attrs):
    rest = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in attrs.items())
    return f'<path d="{d}" fill="{fill}" {rest}/>'


def circle(x, y, r, fill, **attrs):
    rest = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in attrs.items())
    return f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}" {rest}/>'


def ridge(seed, baseline, height, color, offset=0):
    rng = random.Random(seed)
    phase = rng.random() * 5
    points = [(x, baseline + math.sin(x / 240 + phase) * height
               + math.sin(x / 79 + phase) * height * .24
               + math.sin(x / 27) * height * .06 + offset) for x in range(-20, 1621, 14)]
    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in points) + f" V{H} H-20Z"
    return path(d, color)


def pine(x, y, size, color):
    return (path(f"M{x},{y-size} l{-size*.3},{size*.6}h{size*.12}l{-size*.22},{size*.3}"
                 f"h{size*.17}l{-size*.2},{size*.3}h{size*.86}l{-size*.2},{-size*.3}"
                 f"h{size*.17}l{-size*.22},{-size*.3}h{size*.12}Z", color)
            + path(f"M{x-2},{y}v{size*.3}h4v{-size*.3}Z", color))


def start(name, top, bottom):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">'
            f'<title>Original Xodus fixture illustration: {name}</title>'
            '<desc>Authored procedural vector scene, GPL-3.0-only. Not a real game cover.</desc>'
            '<defs>'
            f'<linearGradient id="sky" x2="0" y2="1"><stop stop-color="{top}"/>'
            f'<stop offset="1" stop-color="{bottom}"/></linearGradient>'
            '<linearGradient id="water" x2="0" y2="1"><stop stop-color="#74aebc"/>'
            '<stop offset="1" stop-color="#0a283c"/></linearGradient>'
            '<linearGradient id="shade"><stop stop-color="#07111e" stop-opacity=".40"/>'
            '<stop offset=".55" stop-color="#07111e" stop-opacity="0"/></linearGradient>'
            '<radialGradient id="planet"><stop stop-color="#aac9dd" offset="0"/>'
            '<stop stop-color="#527b9b" offset=".5"/><stop stop-color="#152f50" offset="1"/></radialGradient>'
            '<radialGradient id="halo"><stop stop-color="#fff1ce" stop-opacity=".5"/>'
            '<stop offset="1" stop-color="#fff1ce" stop-opacity="0"/></radialGradient>'
            '<filter id="texture"><feTurbulence baseFrequency=".6" numOctaves="3" seed="31" type="fractalNoise"/>'
            '<feColorMatrix type="saturate" values="0"/></filter>'
            '</defs>'
            '<rect width="1600" height="900" fill="url(#sky)"/>')


def finish():
    return ('<rect width="1600" height="900" filter="url(#texture)" opacity=".055" style="mix-blend-mode:soft-light"/>'
            '<rect width="1600" height="900" fill="url(#shade)"/></svg>')


def harbor():
    rng = random.Random(12)
    s = start("Lumen Harbor: monumental tidal city", "#253c68", "#ebb985")
    s += circle(1100, 290, 290, "url(#halo)") + circle(1100, 290, 83, "#ffe2ae")
    s += ridge(3, 430, 65, "#647899") + ridge(18, 470, 85, "#3d526f")
    s += '<rect y="550" width="1600" height="350" fill="url(#water)"/>'
    for i in range(80):
        x, y = rng.randrange(0, 1600), rng.randrange(590, 880)
        s += path(f"M{x},{y}h{rng.randrange(12,100)}", "none", stroke="#d6d8b5", opacity=".18")
    s += path("M1000,540L1000,390Q1020,375 1040,390V530H1070V290L1115,255L1160,290V510"
              "H1210V350H1290V460H1340V220L1370,192L1400,220V525H1500V360H1600V700Z", "#1b304a")
    s += path("M850,580Q1070,290 1390,430L1410,485Q1100,405 890,630Z", "#213953")
    for x in range(890, 1380, 60):
        top = 428 - 110 * math.sin((x - 850) / 560 * math.pi)
        s += path(f"M{x},{top:.1f}v140", "none", stroke="#718092", stroke_width="2", opacity=".7")
    for i in range(85):
        x, y = rng.randrange(1010, 1600), rng.randrange(350, 520)
        s += path(f"M{x},{y}h4v9h-4Z", "#ffcd8b", opacity=rng.uniform(.3,.85))
    s += ridge(4, 745, 58, "#101f30")
    s += path("M0,660Q160,580 260,665L345,900H0Z", "#0b1a2b")
    for i in range(16):
        x = 40 + i * 15
        s += path(f"M{x},730l60,170", "none", stroke="#425267", stroke_width="1", opacity=".4")
    return s + finish()


def orbit():
    rng = random.Random(44)
    s = start("Orbit Almanac: distant ring world", "#080e26", "#40507f")
    for i in range(240):
        s += circle(rng.randrange(1600), rng.randrange(680), rng.choice([.7,1,1.4,2]),
                    "#d6e6ff", opacity=rng.uniform(.25,.95))
    s += path("M500,0Q800,250 1550,80L1600,230Q900,450 410,80Z", "#ae82aa", opacity=".11")
    s += '<ellipse cx="1160" cy="310" rx="510" ry="91" fill="none" stroke="#d1bfae" stroke-width="38" opacity=".65" transform="rotate(-22 1160 310)"/>'
    s += circle(1160, 310, 230, "url(#planet)")
    s += '<clipPath id="planet-clip"><circle cx="1160" cy="310" r="230"/></clipPath><g clip-path="url(#planet-clip)" opacity=".23">'
    for i in range(12):
        y = 120 + i * 36
        s += path(f"M900,{y}Q1150,{y+65} 1450,{y-30}", "none", stroke="#e4f0f8", stroke_width="12")
    s += '</g>'
    s += circle(720, 170, 38, "#b3aab6") + ridge(9, 710, 55, "#151a32")
    s += ridge(61, 845, 50, "#070d20")
    s += path("M1160,750v-126q-12,-36 30,-46q70,-12 93,43v129Z", "#243653")
    s += '<ellipse cx="1220" cy="620" rx="91" ry="19" fill="#879ab2"/>'
    s += path("M1170,603l60,-77l35,80Z", "#253c5b") + circle(1230, 545, 6, "#f3cb95")
    return s + finish()


def alpine():
    rng = random.Random(20)
    s = start("Paper Ridge: alpine valley", "#47688d", "#e9d3ab")
    s += circle(1000, 240, 260, "url(#halo)")
    s += path("M0,560L210,360L370,470L640,180L820,420L1120,265L1340,470L1600,370V900H0Z", "#77929f")
    s += path("M405,450L640,180L806,420L703,335L678,359L625,255L585,330L550,307Z", "#e3e8dd")
    s += path("M870,438L1120,265L1290,438L1140,359L1100,385L1060,339Z", "#d6e0d8")
    s += path("M650,193L667,343L820,420L747,385Z", "#344f68", opacity=".45")
    s += ridge(14, 620, 90, "#426473")
    s += path("M480,580Q790,540 1210,580L1450,900H300Z", "url(#water)")
    s += ridge(55, 715, 90, "#203f48")
    for i in range(75):
        x = rng.randrange(1600)
        y = 715 + math.sin(x/240)*70 + rng.randrange(130)
        s += pine(x, y, rng.randrange(35,135), "#112f38" if i % 2 else "#1b4148")
    s += path("M20,840Q400,680 650,825L580,900H0Z", "#0e2430")
    return s + finish()


def desert():
    s = start("The Last Signal: desert relay", "#683b50", "#f0b070")
    s += circle(1060, 260, 280, "url(#halo)") + circle(1060, 260, 120, "#f6cc92")
    for i, color in enumerate(["#b06958", "#935548", "#683d3b", "#372933"]):
        s += ridge(40+i, 470+i*100, 70-i*8, color)
    s += path("M1060,680L1095,165L1200,200L1250,690Z", "#252631")
    s += path("M1095,165L1138,200L1150,675L1060,680Z", "#4d3a40")
    s += path("M1130,250L1140,245L1164,555L1152,561Z", "#f2b475", opacity=".8")
    s += path("M1310,690L1335,378L1390,365L1440,702Z", "#272834")
    s += path("M1030,165L1207,204L1230,249L1028,210Z", "#36303a")
    for i in range(18):
        y = 650+i*13
        s += path(f"M0,{y}Q300,{y-45} 620,{y+60}T1600,{y-18}", "none",
                  stroke="#f0b187", stroke_width="1", opacity=".15")
    s += path("M0,842Q470,730 815,900H0Z", "#211e2a")
    return s + finish()


def forest():
    rng = random.Random(18)
    s = start("Moss and Meridian: luminous forest", "#2b5a58", "#becaa0")
    s += circle(1050, 270, 430, "url(#halo)")
    for i in range(45):
        x = rng.randrange(1600)
        s += path(f"M{x},650V{rng.randrange(0,200)}h{rng.randrange(8,22)}V650Z", "#44706b", opacity=".28")
    s += ridge(82, 625, 43, "#4c766b")
    s += path("M950,480Q1130,700 620,900H100Q1020,680 920,480Z", "#9ebca4", opacity=".65")
    for x, width in [(60,100),(260,78),(1300,86),(1530,150)]:
        s += path(f"M{x},900Q{x+40},470 {x-50},-10H{x+width}Q{x+width-45},440 {x+width+70},900Z",
                  "#183a3d")
        s += path(f"M{x+width*.5},400Q{x-40},210 {x-240},160M{x+width*.5},310Q{x+180},180 {x+390},80",
                  "none", stroke="#183a3d", stroke_width="34", stroke_linecap="round")
    for i in range(95):
        x, y = rng.randrange(-100,1700), rng.randrange(-70,340)
        s += f'<ellipse cx="{x}" cy="{y}" rx="{rng.randrange(35,130)}" ry="{rng.randrange(18,58)}" fill="{rng.choice(["#264f49","#366258","#163b3c"])}" opacity=".82"/>'
    for i in range(30):
        s += circle(rng.randrange(350,1300), rng.randrange(300,800), rng.choice([1.5,2,3]), "#f3edbe", opacity=".65")
    s += path("M800,900L920,719L959,719L1140,900Z", "#254640")
    for i in range(10):
        y = 743 + i * 15
        s += path(f"M{905-i*10},{y}h{65+i*23}", "none", stroke="#648276", stroke_width="2")
    return s + finish()


def tidal():
    s = start("Tidal Atlas: wild ocean passage", "#33466b", "#ba9e9f")
    s += circle(1110, 380, 300, "url(#halo)")
    for i in range(7):
        y = 120+i*37
        s += path(f"M0,{y}Q350,{y-75} 700,{y+40}T1600,{y-10}", "none",
                  stroke="#d5c4c2", stroke_width="45", opacity=".09")
    s += ridge(35, 530, 85, "#4c647c")
    s += '<rect y="620" width="1600" height="280" fill="url(#water)"/>'
    s += path("M1050,640L1150,442L1220,394L1290,445L1380,633L1450,710Z", "#263f55")
    s += path("M0,510L200,485L370,565L590,700L0,810Z", "#1d354b")
    for i in range(34):
        y = 625+i*9
        s += path(f"M0,{y}Q300,{y-20} 630,{y+16}T1600,{y-5}", "none",
                  stroke="#cad9ce", stroke_width="1.2", opacity=".2")
    s += path("M885,739L1060,739L1005,781L945,781Z", "#172f45")
    s += path("M971,730V530L1070,724Z", "#d6cbb8") + path("M957,530V730H885Z", "#f0dfbf")
    s += path("M0,790Q260,755 430,900H0Z", "#112334")
    return s + finish()


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, generate in [("harbor", harbor), ("orbit", orbit), ("ridge", alpine),
                           ("signal", desert), ("moss", forest), ("tide", tidal)]:
        svg = generate()
        ET.fromstring(svg)
        (OUT / f"{name}.svg").write_text(svg + "\n", encoding="utf-8")
        print(f"design/artwork/{name}.svg")
