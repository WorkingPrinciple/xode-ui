#!/usr/bin/env python3
"""Read-only package inspection and public requirements research for the rolling queue.

Run with --public to persist both package and public-source observations, then
--apply to update the queue and classification evidence from that saved report.
Run classify_catalogue.py and test_inspect_queue.py after applying it. Collection
without --public produces a local-only report that cannot enrich the whole queue.

sizeBytes is an installed footprint; downloadSizeBytes is the maximum Windows
MSIXVC offer size from the GB catalog. Numeric zero always means unknown when
the corresponding *Known flag is false. Neither is a Steam disk-space estimate.
API values are testing targets, with basis/source fields distinguishing measured
imports from public requirements and engine inferences. Identity fields alone
never establish mandatory Windows sign-in. Clean filename scans never clear
opaque binaries or external anti-cheat components.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import html
import json
import math
import mmap
import re
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from scan_packages import inventory, load_json, package_identity


ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "Sources/OdeManagement/Resources/CompatibilityData"
QA_DATA = ROOT / "Sources/OdeManagement/QA/CompatibilityData"
QUEUE = QA_DATA / "next-30-queue.json"
OUTPUT = QA_DATA / "queue-inspection-v1.json"
SIGNATURES = Path(__file__).with_name("anti-cheat-signatures-v1.json")
GDK_REFERENCE = (
    "https://learn.microsoft.com/en-us/gaming/gdk/docs/reference/system/"
    "microsoftgameconfig/elements/microsoftgameconfig-element-requiresxboxlive"
)
API_DLLS = {
    "d3d9.dll": "DX9",
    "d3d10.dll": "DX10",
    "d3d10_1.dll": "DX10",
    "d3d11.dll": "DX11",
    "d3d12.dll": "DX12",
    "vulkan-1.dll": "Vulkan",
    "opengl32.dll": "OpenGL",
}
SEARCH_NAMES = {
    "9NGLST31DG26": "A Game About Digging A Hole",
    "9P2J5D12GJL5": "The Elder Scrolls IV: Oblivion Game of the Year Edition (2009)",
    "9PJPCB188SVG": "Subnautica 2",
    "9P03JGQ4S1GC": "The Elder Scrolls V: Skyrim Special Edition",
    "9P1N07XDL1D4": "Dishonored",
    "9PJ8266BHFWN": None,
}
STEAM_IDS = {"9NCJWHHMVHR0": 3043580}
ALTERNATIVES = {
    "9NKV34XDW014": ("Palworld", None,
                       "Xbox build multiplayer/services integration is unverified; "
                       "not established as universally blocked."),
    "9PJTHRNVH62H": ("Grounded", None,
                       "Xbox services/multiplayer integration is unverified; "
                       "not established as universally blocked."),
    "9P2N57MC619K": ("Sea of Thieves", "Easy Anti-Cheat",
                       "Named anti-cheat excludes this title under the 0.1 policy."),
    "9NKX70BBCDRN": ("Forza Horizon 5", None,
                       "Xbox package/identity and anti-cheat behavior require verification; "
                       "do not infer no blocker from a missing AWACY record."),
    "9NCJSXWZTP88": ("Starfield", None,
                       "Large DX12 title; no observed local runtime or compatibility pass. "
                       "A demanding API is not itself proof of incompatibility."),
    "9N0H62KZ3BXV": ("Diablo IV", None,
                       "Battle.net provider route is outside the active MSIXVC/native-Minecraft "
                       "queue. Publisher launcher required; no ordinary MSIXVC support claim."),
    "9NTM9HXNLSZX": ("Halo: The Master Chief Collection", "Easy Anti-Cheat",
                       "Named anti-cheat excludes this title under the 0.1 policy even if "
                       "some modes or other platforms can disable/support EAC."),
}
API_FACTS = {
    "BQVQTL3PCH05": (
        "Vulkan", "publisher-and-package-layout",
        "https://www.nomanssky.com/2019/04/vulkan-update/",
        "Hello Games states OpenGL was replaced by Vulkan; installed Binaries/vulkan-1.dll agrees.",
    ),
    "9NGLST31DG26": (
        "DX12", "package-layout-inference",
        "https://www.pcgamingwiki.com/wiki/A_Game_About_Digging_A_Hole",
        "Unreal layout and shipped D3D12Core.dll suggest DX12; opaque main images prevent "
        "import confirmation. PCGamingWiki identifies Unreal Engine 5. Runtime API unverified.",
    ),
    "9PLH7R84GJWP": (
        "DX11", "engine-inference",
        "https://manual.gamemaker.io/monthly/en/Settings/Game_Options/Windows.htm",
        "data.win identifies the GameMaker Windows runner; DX11 is a testing hypothesis based "
        "on that engine, not a title-specific import or runtime confirmation.",
    ),
    "9MWR1NC6VQ6L": (
        "OpenGL", "managed-backend-marker",
        "https://www.pcgamingwiki.com/wiki/Stardew_Valley",
        "Installed MonoGame.Framework.dll contains MonoGame.OpenGL and DesktopGL metadata; "
        "main EXE is opaque. Steam DX10 minimum requirements do not identify this Xbox backend.",
    ),
    "9NV3L234VGXD": (
        "DX11", "renderer-library-import",
        "https://store.steampowered.com/app/1663850/",
        "Installed UnityPlayer.dll imports d3d11.dll, d3d12.dll and opengl32.dll. DX11 is "
        "the first backend to test, not an observed active renderer; all imports are listed.",
    ),
    "9NH0MSG29X6L": (
        "DX12", "package-layout-inference",
        "https://store.steampowered.com/app/2582320/",
        "Unreal layout with NewMoon/Binaries/WinGDK/D3D12/x64/D3D12Core.dll suggests DX12. "
        "Both main and shipping images are opaque; runtime API is unverified.",
    ),
    "9PJ8266BHFWN": (
        "OpenGL", "public-title-reference",
        "https://www.pcgamingwiki.com/wiki/Minecraft",
        "Java Edition uses the OpenGL/LWJGL renderer, not the Xbox MCPlaceholderStub.exe. "
        "This queue row launches through the separately verified native macOS provider.",
    ),
    "9P03JGQ4S1GC": (
        "DX11", "public-title-reference",
        "https://www.pcgamingwiki.com/wiki/The_Elder_Scrolls_V:_Skyrim_Special_Edition",
        "PCGamingWiki API table and Windows requirements identify DirectX 11; installed "
        "Creation-engine layout agrees. Both local images are opaque; no import result.",
    ),
    "9N4W31HSMVVD": (
        "DX12", "public-title-reference",
        "https://www.pcgamingwiki.com/wiki/Kingdom_Come:_Deliverance_II",
        "PCGamingWiki API table identifies DirectX 12. No local Xbox package was inspected.",
    ),
    "C3KLDKZBHNCZ": (
        "DX11", "package-layout-inference",
        "https://www.pcgamingwiki.com/wiki/Fallout_4",
        "Creation-engine Data/Fallout4.esm and GFSDK_SSAO_D3D11.win64.dll identify a DX11 "
        "integration; main/launcher images are opaque. No runtime API pass is implied.",
    ),
    "9NQVHHW88XW9": (
        "DX11", "public-title-reference",
        "https://www.pcgamingwiki.com/wiki/Bluey%27s_Happy_Snaps",
        "PCGamingWiki Windows requirements explicitly say DirectX 11 compatible. "
        "No local Xbox package was inspected.",
    ),
    "9NCJWHHMVHR0": (
        "DX12", "public-title-reference",
        "https://www.pcgamingwiki.com/wiki/Keeper",
        "PCGamingWiki Windows requirements explicitly say DirectX 12 compatible and "
        "Shader Model 6. No local Xbox package was inspected.",
    ),
}


class InvalidPE(ValueError):
    pass


def pe_imports(path: Path) -> dict[str, Any]:
    """Parse normal and delay-load import names without executing the image."""
    with path.open("rb") as handle:
        header = handle.read(64)
        result: dict[str, Any] = {
            "sizeBytes": path.stat().st_size,
            "headerSha256": hashlib.sha256(header).hexdigest(),
        }
        if len(header) < 64 or header[:2] != b"MZ":
            return {**result, "status": "opaque-or-not-PE", "imports": []}
        try:
            with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as image:
                def unpack(fmt: str, offset: int) -> tuple[Any, ...]:
                    length = struct.calcsize(fmt)
                    if offset < 0 or offset + length > len(image):
                        raise InvalidPE("PE table outside file")
                    return struct.unpack_from(fmt, image, offset)

                pe = unpack("<I", 60)[0]
                if image[pe:pe + 4] != b"PE\0\0":
                    raise InvalidPE("Missing PE signature")
                section_count = unpack("<H", pe + 6)[0]
                optional_size = unpack("<H", pe + 20)[0]
                optional = pe + 24
                magic = unpack("<H", optional)[0]
                if magic not in {0x10B, 0x20B}:
                    raise InvalidPE("Unsupported optional header")
                directories = optional + (96 if magic == 0x10B else 112)
                directory_count = unpack("<I", directories - 4)[0]
                image_base = unpack("<I" if magic == 0x10B else "<Q",
                                    optional + (28 if magic == 0x10B else 24))[0]
                sections = []
                for index in range(section_count):
                    offset = optional + optional_size + index * 40
                    virtual_size, virtual_address, raw_size, raw_address = unpack(
                        "<IIII", offset + 8
                    )
                    sections.append((virtual_address, virtual_size, raw_address, raw_size))
                headers_size = unpack("<I", optional + 60)[0]

                def file_offset(rva: int) -> int:
                    if 0 <= rva < min(headers_size, len(image)):
                        return rva
                    for virtual_address, virtual_size, raw_address, raw_size in sections:
                        delta = rva - virtual_address
                        if 0 <= delta < max(virtual_size, raw_size):
                            if delta >= raw_size or raw_address + delta >= len(image):
                                raise InvalidPE("Import RVA has no file backing")
                            return raw_address + delta
                    raise InvalidPE("Import RVA outside sections")

                imports: set[str] = set()
                for directory_index, stride, name_index in ((1, 20, 3), (13, 32, 1)):
                    if directory_count <= directory_index:
                        continue
                    directory_offset = directories + directory_index * 8
                    if directory_offset + 8 > optional + optional_size:
                        raise InvalidPE("Data directory outside optional header")
                    rva, size = unpack("<II", directory_offset)
                    if rva == 0:
                        continue
                    table = file_offset(rva)
                    terminated = False
                    for index in range(min(size // stride, 8192)):
                        fields = unpack("<" + "I" * (stride // 4), table + index * stride)
                        if not any(fields):
                            terminated = True
                            break
                        name_rva = fields[name_index]
                        if directory_index == 13 and not fields[0] & 1:
                            name_rva -= image_base
                        start = file_offset(name_rva)
                        end = image.find(b"\0", start, min(start + 512, len(image)))
                        if end < 0:
                            raise InvalidPE("Unterminated import name")
                        imports.add(image[start:end].decode("ascii").lower())
                    if not terminated:
                        raise InvalidPE("Unterminated import descriptors")
                return {
                    **result,
                    "status": "parsed",
                    "imports": sorted(imports),
                    "graphicsAPIs": sorted({API_DLLS[name] for name in imports if name in API_DLLS}),
                    "dxgi": "dxgi.dll" in imports,
                    "backendMarkers": [
                        marker for marker in ("MonoGame.OpenGL", "DesktopGL", "FNA3D")
                        if image.find(marker.encode("ascii")) >= 0
                    ] if path.name.lower() in {"monogame.framework.dll", "fna.dll"} else [],
                }
        except (InvalidPE, UnicodeDecodeError, struct.error) as error:
            return {**result, "status": "invalid-or-protected-PE", "error": str(error), "imports": []}


def inspect_package(item: dict[str, Any], signatures: list[dict[str, Any]]) -> dict[str, Any]:
    root = Path(item["installRoot"]).expanduser().resolve(strict=True)
    identity = package_identity(root, item["storeId"])
    manifest = root / identity["manifest"]
    document = ET.parse(manifest).getroot()
    metadata: dict[str, list[str]] = {}
    executables = []
    for element in document.iter():
        tag = element.tag.rsplit("}", 1)[-1]
        if tag in {"RequiresXboxLive", "XblGameTitle", "MSAAppId", "TitleId"}:
            metadata.setdefault(tag, []).append((element.text or "").strip())
        if tag == "Executable":
            executables.append(element.attrib["Name"].replace("\\", "/"))
    files = sorted(
        path for path in root.rglob("*")
        if path.is_file() and not path.is_symlink()
    )
    relative_files = [path.relative_to(root).as_posix() for path in files]
    names = {path.name.lower() for path in files}
    engine_markers: dict[str, list[str]] = {}
    for relative in relative_files:
        lower = relative.lower()
        engine = None
        if lower.endswith("unityplayer.dll") or "_data/globalgamemanagers" in lower:
            engine = "Unity"
        elif lower.startswith("engine/binaries/") or "/binaries/wingdk/" in lower:
            engine = "Unreal"
        elif lower.endswith("fna.dll"):
            engine = "FNA"
        elif lower.endswith("monogame.framework.dll"):
            engine = "MonoGame"
        elif lower.endswith("godot.windows.template_release.x86_64.exe"):
            engine = "Godot"
        elif lower in {"data/skyrim.esm", "data/fallout4.esm"}:
            engine = "Creation"
        elif lower.endswith("data/oblivion.esm"):
            engine = "Gamebryo"
        elif lower == "data.win":
            engine = "GameMaker"
        elif lower == "love.exe":
            engine = "LOVE"
        elif lower == "whgame.dll":
            engine = "CryEngine"
        if engine:
            engine_markers.setdefault(engine, []).append(relative)
    selected = set(executables)
    for relative in relative_files:
        lower = relative.lower()
        if (
            lower.endswith("-shipping.exe")
            or Path(lower).name in {
                "unityplayer.dll", "whgame.dll", "skyrimse.exe", "fallout4.exe",
                "oblivion.exe", "monogame.framework.dll", "fna.dll", "sdl2.dll",
                "libegl.dll", "libglesv2.dll",
            }
        ):
            selected.add(relative)
    binaries = []
    for relative in sorted(selected):
        path = (root / relative).resolve()
        if not path.is_relative_to(root):
            raise RuntimeError(f"Executable path escapes package root: {relative}")
        if not path.is_file():
            binaries.append({"path": relative, "status": "missing", "imports": []})
        else:
            binaries.append({"path": relative, **pe_imports(path)})
    return {
        "root": item["installRoot"],
        "identity": identity,
        "manifestSha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
        "metadata": metadata,
        "metadataReference": GDK_REFERENCE,
        "signInInterpretation": (
            "RequiresXboxLive applies to Console devices only. TitleId, XblGameTitle and "
            "MSAAppId identify Xbox integration, not mandatory Windows sign-in. "
            "Do not infer signInNeeded=false from a missing element or console false."
        ),
        "executables": executables,
        "engineMarkers": {key: value[:12] for key, value in sorted(engine_markers.items())},
        "graphicsAPIs": sorted({api for binary in binaries for api in binary.get("graphicsAPIs", [])}),
        "binaries": binaries,
        "antiCheatScan": inventory(root, signatures),
        "rendererFiles": [relative for relative in relative_files if re.search(
            r"(d3d1[12]|vulkan|opengl|renderer|renderd3d|fna3d)", relative, re.I
        )][:35],
        "hasXboxIdentity": bool(metadata.get("TitleId") or metadata.get("MSAAppId")
                                or metadata.get("XblGameTitle")),
        "hasUnityPlayer": "unityplayer.dll" in names,
    }


def fetch_json(url: str) -> Any:
    request = urllib.request.Request(url, headers={"User-Agent": "OdeClassification/1.0"})
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def normalized(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower().replace("™", "").replace("®", ""))


def text(value: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", " ", value)).strip()


def public_requirements(item: dict[str, Any]) -> dict[str, Any]:
    name = SEARCH_NAMES.get(item["storeId"], item["title"])
    if name is None:
        return {"status": "native-provider-not-on-Steam"}
    search_url = "https://store.steampowered.com/api/storesearch/?" + urllib.parse.urlencode(
        {"term": name, "cc": "gb", "l": "english"}
    )
    search = fetch_json(search_url)
    hits = search.get("items", [])
    exact = [hit for hit in hits if normalized(hit["name"]) == normalized(name)]
    if item["storeId"] in STEAM_IDS:
        exact = [{"id": STEAM_IDS[item["storeId"]]}]
    if not exact:
        return {"status": "no-exact-Steam-match", "searchURL": search_url,
                "matches": [{"name": hit["name"], "appID": hit["id"]} for hit in hits[:5]]}
    app_id = exact[0]["id"]
    details_url = f"https://store.steampowered.com/api/appdetails?appids={app_id}&cc=gb&l=english"
    response = fetch_json(details_url).get(str(app_id), {})
    if not response.get("success"):
        raise RuntimeError(f"Steam appdetails returned success=false for {app_id}")
    data = response["data"]
    if data.get("type") != "game" or normalized(data["name"]) != normalized(name):
        raise RuntimeError(f"Steam product mismatch for {item['storeId']}: {data.get('name')}")
    result = {
        "status": "matched",
        "name": data["name"],
        "appID": app_id,
        "source": f"https://store.steampowered.com/app/{app_id}/",
        "detailsURL": details_url,
        "minimum": text(data.get("pc_requirements", {}).get("minimum", "")),
        "recommended": text(data.get("pc_requirements", {}).get("recommended", "")),
        "releaseDate": data.get("release_date"),
        "requiredAccount": data.get("required_account"),
        "categories": [category["description"] for category in data.get("categories", [])],
        "scope": "Steam Windows requirements; Xbox Store build may differ.",
    }
    reviews_url = f"https://store.steampowered.com/appreviews/{app_id}?json=1&language=all&purchase_type=all&num_per_page=0"
    reviews = fetch_json(reviews_url)
    if reviews.get("success") != 1:
        raise RuntimeError(f"Steam reviews returned failure for {app_id}")
    result["popularity"] = {
        "source": reviews_url,
        "metric": "Steam total user reviews, not player count or Xbox popularity",
        "totalReviews": reviews.get("query_summary", {}).get("total_reviews", 0),
    }
    return result


def catalog_sizes(item: dict[str, Any]) -> dict[str, Any]:
    url = "https://displaycatalog.mp.microsoft.com/v7.0/products?" + urllib.parse.urlencode(
        {"bigIds": item["storeId"], "market": "GB", "languages": "en-GB"}
    )
    response = fetch_json(url)
    products = response.get("Products", [])
    if len(products) != 1 or products[0].get("ProductId") != item["storeId"]:
        return {"source": url, "status": "no-matching-product", "packages": []}
    packages = []
    for availability in products[0].get("DisplaySkuAvailabilities", []):
        sku = availability.get("Sku", {})
        for package in sku.get("Properties", {}).get("Packages", []):
            packages.append({
                "skuID": sku.get("SkuId"),
                **{key: value for key, value in package.items()
                   if any(token in key.lower() for token in ("size", "format", "platform", "device"))},
            })
    return {"source": url, "status": "matched", "packages": packages}


def positive_sizes(catalog: dict[str, Any]) -> list[int]:
    return sorted({
        package["MaxDownloadSizeInBytes"] for package in catalog.get("packages", [])
        if package.get("PackageFormat") in {"MSIXVC", "MSIXVCBundle"}
        and isinstance(package.get("MaxDownloadSizeInBytes"), int)
        and not isinstance(package["MaxDownloadSizeInBytes"], bool)
        and package["MaxDownloadSizeInBytes"] > 0
    })


def update_queue(report: dict[str, Any]) -> None:
    queue = load_json(QUEUE)
    catalogue_path = DATA / "game-compatibility-v1.json"
    catalogue = load_json(catalogue_path)
    if not isinstance(report.get("assessedAlternatives"), list) or any(
        not isinstance(report.get("products", {}).get(item["storeId"], {}).get(key), dict)
        for item in queue["items"] for key in ("steam", "catalog")
    ):
        raise RuntimeError("Applying requires a complete --public report for all queue products")
    checked_at = report["checkedAt"][:10]
    candidates = {item["productID"]: item for item in catalogue["testCandidates"]["items"]}
    for item in queue["items"]:
        product_id = item["storeId"]
        evidence = report["products"][product_id]
        package = evidence.get("package")
        steam = evidence.get("steam", {})
        catalog = evidence.get("catalog", {})
        candidate = candidates[product_id]
        source_reference = f"{OUTPUT.name}#/products/{product_id}"
        item["inspectionEvidence"] = source_reference
        item["checkedAt"] = checked_at
        item["sizeBytes"] = item["sizeBytes"] or 0
        item["sizeKnown"] = item["sizeBytes"] > 0
        sizes = positive_sizes(catalog)
        item["downloadSizeBytes"] = max(sizes, default=0)
        item["downloadSizeKnown"] = bool(sizes)
        item["downloadSizeEvidence"] = {
            "source": catalog.get("source"),
            "checkedAt": checked_at,
            "basis": "Maximum Windows MSIXVC catalog MaxDownloadSizeInBytes across offers; "
                     "not measured transfer bytes. Zero means unknown, never zero-cost.",
            "observedSizesBytes": sizes,
        }
        if steam.get("status") == "matched":
            item["releaseStatus"] = steam["releaseDate"]
            candidate["releaseStatus"] = steam["releaseDate"]
            item["releaseEvidenceSource"] = steam["source"]
            item["popularityEvidence"] = {
                **steam["popularity"], "checkedAt": checked_at,
            }
            candidate["popularityEvidenceURL"] = steam["popularity"]["source"]
            candidate["popularityMetric"] = steam["popularity"]["metric"]
        minimum = steam.get("minimum", "")
        match = re.search(r"DirectX(?:®)?\s*:\s*(?:(?:Version|DirectX)\s*)?(\d+)", minimum, re.I)
        if match is None:
            match = re.search(r"DirectX\s+(\d+)\s+compatible", minimum, re.I)
        if product_id in API_FACTS:
            api, basis, source, explanation = API_FACTS[product_id]
        elif match is not None:
            api = "DX" + match[1]
            basis = "public-Windows-requirement"
            source = steam["source"]
            explanation = (
                f"Exact title Steam Windows minimum requirements specify DirectX {match[1]}. "
                "This is a public requirement, not an import scan or proof of the Xbox renderer."
            )
        elif "OpenGL" in minimum:
            api, basis, source = "OpenGL", "public-Windows-requirement", steam["source"]
            explanation = "Exact title Steam Windows minimum requirements specify OpenGL."
        else:
            raise RuntimeError(f"{product_id}: no sourced graphics API; refusing a guessed value")
        item.update(api=api, apiBasis=basis, apiEvidence=explanation,
                    apiEvidenceSource=source, apiEvidenceCheckedAt=checked_at)
        item["apiAlternatives"] = package.get("graphicsAPIs", []) if package else []
        item["engine"] = list(package["engineMarkers"]) if package else []
        item["signInNeeded"] = True if product_id == "9PJ8266BHFWN" else None
        item["signInStatus"] = (
            "Microsoft account required for Java Edition/native launcher; public title reference."
            if item["signInNeeded"] is True else
            "Mandatory Windows title sign-in is unverified; console-only RequiresXboxLive "
            "and Xbox identity fields do not establish it. Store entitlement is separate."
        )
        item["signInEvidence"] = {
            "source": "https://www.pcgamingwiki.com/wiki/Minecraft"
                      if item["signInNeeded"] is True else GDK_REFERENCE,
            "checkedAt": checked_at,
            "manifestFields": package["metadata"] if package else None,
            "hasXboxIdentity": package["hasXboxIdentity"] if package else None,
            "packageInspected": package is not None,
            "basis": "public-title-reference" if item["signInNeeded"] is True
                     else "manifest-insufficient" if package else "not-installed",
        }
        if package is not None:
            scan = package["antiCheatScan"]
            item["antiCheatScanStatus"] = "named-match" if scan["matches"] else "no-known-path-signature"
            item["antiCheatScanEvidence"] = source_reference + "/package/antiCheatScan"
            product = catalogue["products"][product_id]
            if product["antiCheat"] == "unknown":
                if scan["matches"]:
                    raise RuntimeError(f"{product_id}: named anti-cheat found; review before applying")
                prior = product["antiCheatEvidence"]
                product["antiCheatEvidence"] = {
                    **prior,
                    "checkedAt": checked_at,
                    "type": "unknown",
                    "method": (
                        "Rescanned all available package paths with the versioned anti-cheat "
                        "filename signature set, including Easy Anti-Cheat, BattlEye, Vanguard, "
                        "GameGuard and XIGNCODE. No known filename matched. Opaque executable "
                        "contents and remote components are not cleared by a path scan. "
                        "Previously cited public checks did not affirm absence; unknown is retained."
                    ),
                    "packageScan": {
                        **scan,
                        "packageIdentity": package["identity"],
                        "root": package["root"],
                        "signatureSet": SIGNATURES.name,
                        "signatureVersion": load_json(SIGNATURES)["version"],
                        "result": "no-known-signature",
                        "scope": "Available filesystem paths only; not proof of full extraction"
                                 + ("; Minecraft Windows entitlement stub, not Java runtime"
                                    if product_id == "9PJ8266BHFWN" else ""),
                    },
                }
                item["antiCheatEvidenceCheckedAt"] = checked_at
        else:
            item["antiCheatScanStatus"] = "not-installed"
        release_status = item.get("releaseStatus")
        item["testEligibility"] = (
            "defer-unreleased" if isinstance(release_status, dict) and release_status.get("coming_soon")
            else "native-provider" if product_id == "9PJ8266BHFWN"
            else "test-unverified" if item["antiCheat"] == "unknown"
            else "test-anti-cheat-cleared"
        )
        item["blockingNotes"] = []
        if candidate.get("packageScanBlocker"):
            item["blockingNotes"].append(candidate["packageScanBlocker"])
        if item["testEligibility"] == "defer-unreleased":
            item["blockingNotes"].append(
                "Steam reports coming_soon; catalog package may be a preorder stub. "
                "Do not stage a download based on its tiny catalog size."
            )
        if product_id == "9PJ8266BHFWN":
            item["blockingNotes"].append(
                "Package root and download size describe the Windows entitlement stub, "
                "not Java game content. Use native provider minecraft-java-native-macos; "
                "the signed macOS launcher was inspected separately, not proven in-world."
            )
        if item["antiCheat"] == "unknown":
            item["blockingNotes"].append(
                "No affirmative absence evidence; a clean filename scan does not prove no "
                "embedded or remotely loaded anti-cheat. Eligible only for unverified testing."
            )
    first = [item for item in queue["items"] if item["alreadyInstalled"]]
    remaining = [item for item in queue["items"] if not item["alreadyInstalled"]]
    # Installed retests avoid new downloads; mandatory identities remain visible, not excluded.
    def remaining_key(item: dict[str, Any]) -> tuple[Any, ...]:
        popularity = item.get("popularityEvidence", {}).get("totalReviews", 0)
        size_gib = item["downloadSizeBytes"] / (1024 ** 3)
        score = math.log10(1 + popularity) / (1 + size_gib / 10)
        item["rankingScore"] = round(score, 6)
        return (
            item["testEligibility"] == "defer-unreleased",
            item["antiCheat"] not in {"none", "unknown"},
            {False: 0, None: 1, True: 2}[item["signInNeeded"]],
            not item["downloadSizeKnown"],
            -score,
        )
    remaining.sort(key=remaining_key)
    queue["items"] = first + remaining
    for rank, item in enumerate(queue["items"], 1):
        item["rank"] = rank
        candidate = candidates[item["storeId"]]
        candidate["rank"] = rank
        if "rankingScore" in item:
            candidate["priorityScore"] = item["rankingScore"]
    catalogue["testCandidates"]["items"] = [candidates[item["storeId"]] for item in queue["items"]]
    method = (
        "Already-installed retests first, retaining their prior relative order. Remaining titles "
        "rank released ahead of unreleased, exclude named anti-cheat, prefer known no-sign-in "
        "over unknown over required, then known catalog size, then descending "
        "log10(1 + Steam total reviews)/(1 + Windows MSIXVC catalog download GiB/10). "
        "Steam review count is an audience proxy, not player count or Xbox popularity. "
        "Unknown sign-in/anti-cheat is not a no-sign-in/no-cheat claim; preorders/stubs go last."
    )
    queue["rankingMethod"] = method
    catalogue["testCandidates"]["rankingMethod"] = method
    catalogue["testCandidates"]["generatedAt"] = checked_at
    queue["generatedAt"] = report["checkedAt"]
    queue["fieldNotes"].update({
        "api": "Sourced testing API; apiBasis distinguishes requirements, engine/layout inference "
               "and renderer-library imports. Not an observed active renderer. DX9/DX10/OpenGL "
               "are preserved rather than relabeled DX11.",
        "sizeBytes": "Installed-root footprint, not download size. Always numeric; "
                     "0 plus sizeKnown=false means not measured.",
        "downloadSizeBytes": "Always numeric. Windows MSIXVC catalog maximum download bytes, "
                             "not Steam disk requirement. 0 plus downloadSizeKnown=false means unknown.",
        "signInNeeded": "True only with title-specific public/runtime evidence, false only with "
                        "verified optional/offline behavior, null if unverified. RequiresXboxLive "
                        "is console-only; Xbox identity presence does not imply mandatory sign-in.",
    })
    queue["assessedAlternatives"] = report["assessedAlternatives"]
    for alternative in queue["assessedAlternatives"]:
        named = alternative["namedAntiCheatObserved"]
        if named:
            alternative["antiCheat"] = "; ".join(named)
            if alternative["title"] == "Diablo IV":
                alternative["decision"] = "excluded-provider-and-named-anti-cheat"
            product = catalogue["products"][alternative["storeId"]]
            product["antiCheat"] = alternative["antiCheat"]
            product["supported01"] = False
            product["antiCheatEvidence"] = {
                "checkedAt": checked_at, "type": "public-source", "sourceType": "awacy",
                "source": catalogue["antiCheatReference"],
                "method": "Exact normalized title in the pinned AWACY dataset explicitly lists "
                          + alternative["antiCheat"]
                          + ". Its Linux status is not a macOS/Ode runtime acceptance result.",
                "mode": "named-technology",
            }
    for path, data in ((QUEUE, queue), (catalogue_path, catalogue)):
        path.write_text(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
                        encoding="utf-8")


def inspect_item(item: dict[str, Any], signatures: list[dict[str, Any]], public: bool) -> tuple[str, dict[str, Any]]:
    result: dict[str, Any] = {}
    if item["alreadyInstalled"]:
        result["package"] = inspect_package(item, signatures)
    if public:
        for key, operation in (("steam", public_requirements), ("catalog", catalog_sizes)):
            try:
                result[key] = operation(item)
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, RuntimeError) as error:
                result[key] = {"status": "error", "error": str(error)}
                print(f"{item['storeId']} {key}: {error}", file=sys.stderr)
    return item["storeId"], result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public", action="store_true", help="also fetch public Steam/GB catalog evidence")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--apply", action="store_true", help="apply the saved report to queue metadata")
    args = parser.parse_args()
    if args.apply:
        update_queue(load_json(args.output))
        return
    queue = load_json(QUEUE)
    signatures = load_json(SIGNATURES)["signatures"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        futures = [
            executor.submit(inspect_item, item, signatures, args.public)
            for item in queue["items"]
        ]
        products = dict(future.result() for future in futures)
    report = {
        "schemaVersion": 1,
        "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "method": (
            "Read-only PE normal/delay import tables and engine path markers, package manifest "
            "fields, anti-cheat filename signatures, and public source metadata. No game execution. "
            "Opaque files are not presumed encrypted; no runtime API or sign-in pass is implied."
        ),
        "signatureSet": SIGNATURES.name,
        "signatureSetSha256": hashlib.sha256(SIGNATURES.read_bytes()).hexdigest(),
        "products": products,
    }
    if args.public:
        catalogue = load_json(DATA / "game-compatibility-v1.json")
        awacy_url = catalogue["antiCheatReference"]
        awacy = fetch_json(awacy_url)
        alternatives = []
        for product_id, (title, expected_anti_cheat, note) in ALTERNATIVES.items():
            public = public_requirements({"storeId": product_id, "title": title})
            anticheats = {
                anticheat for game in awacy if normalized(game["name"]) == normalized(title)
                for anticheat in game.get("anticheats", [])
            }
            if expected_anti_cheat is not None and expected_anti_cheat not in anticheats:
                raise RuntimeError(f"{title}: pinned anti-cheat evidence did not match")
            alternatives.append({
                "storeId": product_id, "title": title, "checkedAt": report["checkedAt"][:10],
                "antiCheat": "; ".join(sorted(anticheats)) if anticheats else "unknown",
                "antiCheatEvidenceSource": awacy_url,
                "namedAntiCheatObserved": sorted(anticheats),
                "decision": "excluded-provider-and-named-anti-cheat"
                            if title == "Diablo IV" and anticheats
                            else "excluded-named-anti-cheat" if anticheats
                            else "excluded-provider-route" if title == "Diablo IV"
                            else "deferred-unverified-not-proven-blocked",
                "note": note, "steam": public,
                "providerEvidenceSource": "https://us.shop.battle.net/en-us/product/diablo-iv"
                                          if title == "Diablo IV" else None,
            })
        report["assessedAlternatives"] = alternatives
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for product_id, result in products.items():
        package = result.get("package", {})
        steam = result.get("steam", {})
        print(product_id, package.get("graphicsAPIs", []), list(package.get("engineMarkers", {})),
              steam.get("name", steam.get("status", "")), steam.get("minimum", ""))


if __name__ == "__main__":
    main()
