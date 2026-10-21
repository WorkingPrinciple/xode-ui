#!/usr/bin/env python3
"""Inventory installed package paths and record anti-cheat scan evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "Sources/XodusManagement/Resources/CompatibilityData"
CATALOGUE = DATA_DIR / "game-compatibility-v1.json"
PUBLISHER_EVIDENCE = DATA_DIR / "publisher-anti-cheat-v1.json"
SIGNATURES = Path(__file__).with_name("anti-cheat-signatures-v1.json")
PRODUCT_ID = re.compile(r"^[A-Z0-9]{12}$")


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def parse_root(value: str) -> tuple[str, Path]:
    product_id, separator, raw_path = value.partition("=")
    if not separator or not PRODUCT_ID.fullmatch(product_id) or not raw_path:
        raise argparse.ArgumentTypeError("roots must be PRODUCTID=/absolute/path")
    path = Path(raw_path).expanduser().resolve(strict=True)
    if not path.is_dir():
        raise argparse.ArgumentTypeError(f"package root is not a directory: {path}")
    return product_id, path


def parse_public_source(value: str) -> tuple[str, str, str, str]:
    product_id, separator, rest = value.partition("=")
    kind, separator2, rest = rest.partition("=")
    url, separator3, result = rest.partition("=")
    if (
        not separator
        or not separator2
        or not separator3
        or not PRODUCT_ID.fullmatch(product_id)
        or kind not in {"pcgamingwiki", "publisher"}
        or not url.startswith("https://")
        or result != "no-anticheat-record"
    ):
        raise argparse.ArgumentTypeError(
            "public checks must be PRODUCTID=pcgamingwiki|publisher=https-url=no-anticheat-record"
        )
    return product_id, kind, url, result


def inventory(root: Path, signatures: list[dict[str, Any]]) -> dict[str, Any]:
    files: list[str] = []
    paths: list[str] = []
    symlinks: list[str] = []

    def raise_walk_error(error: OSError) -> None:
        raise error

    for current, directories, filenames in os.walk(
        root, topdown=True, followlinks=False, onerror=raise_walk_error
    ):
        current_path = Path(current)
        relative_directory = current_path.relative_to(root)
        if relative_directory.parts:
            paths.append(relative_directory.as_posix())
        kept_directories: list[str] = []
        for name in sorted(directories):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            paths.append(relative)
            if path.is_symlink():
                symlinks.append(relative)
            else:
                kept_directories.append(name)
        directories[:] = kept_directories
        for name in sorted(filenames):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            paths.append(relative)
            if path.is_symlink():
                symlinks.append(relative)
            elif path.is_file():
                files.append(relative)
            else:
                raise RuntimeError(f"Non-regular package entry requires manual review: {relative}")

    file_list = "\n".join(sorted(files)) + ("\n" if files else "")
    matches: dict[str, list[str]] = {}
    for signature in signatures:
        compiled = [re.compile(pattern, re.IGNORECASE) for pattern in signature["patterns"]]
        selected = sorted(
            path
            for path in paths
            if any(pattern.search(path) for pattern in compiled)
        )
        if selected:
            matches[signature["technology"]] = selected
    return {
        "fileCount": len(files),
        "fileListSha256": hashlib.sha256(file_list.encode("utf-8")).hexdigest(),
        "matches": matches,
        "symlinkCount": len(symlinks),
        "complete": not symlinks,
    }


def package_identity(root: Path, product_id: str) -> dict[str, str]:
    manifests = [root / "MicrosoftGame.config", root / "MicrosoftGame.Config"]
    manifest = next((path for path in manifests if path.is_file()), None)
    if manifest is None:
        raise RuntimeError(f"No MicrosoftGame.config found in package root {root}")
    document = ET.parse(manifest).getroot()
    store_ids = [
        (element.text or "").strip()
        for element in document.iter()
        if element.tag.rsplit("}", 1)[-1] == "StoreId"
    ]
    if store_ids != [product_id]:
        raise RuntimeError(
            f"{manifest.name} StoreId {store_ids!r} does not match {product_id}"
        )
    identities = [
        element
        for element in document.iter()
        if element.tag.rsplit("}", 1)[-1] == "Identity"
    ]
    if len(identities) != 1:
        raise RuntimeError(f"Expected one Identity in {manifest.name}")
    identity = identities[0]
    name = identity.get("Name")
    version = identity.get("Version")
    if not name or not version:
        raise RuntimeError(f"Identity name/version missing in {manifest.name}")
    return {"manifest": manifest.name, "name": name, "version": version, "storeId": product_id}


def update_product(
    database: dict[str, Any],
    product_id: str,
    package_root: Path,
    checked_sources: list[tuple[str, str, str, str]],
    signatures: dict[str, Any],
    publisher_products: dict[str, Any],
    checked_at: str,
) -> dict[str, Any]:
    product = database["products"].get(product_id)
    if product is None:
        raise RuntimeError(f"Product is not in the catalogue: {product_id}")
    if product.get("packageFormat") != "MSIXVC":
        raise RuntimeError(f"{product_id} is not catalogued as MSIXVC; refusing a 0.1 scan")
    if product.get("antiCheat") not in {"unknown", "none"}:
        raise RuntimeError(f"{product_id} has a named anti-cheat value; it always wins")
    if product.get("technologyReferences"):
        raise RuntimeError(f"{product_id} has public anti-cheat technology references")
    if product_id in publisher_products:
        raise RuntimeError(f"{product_id} has publisher evidence; a no-cheat scan cannot override it")

    scan = inventory(package_root, signatures["signatures"])
    identity = package_identity(package_root, product_id)
    sources_for_product = [entry for entry in checked_sources if entry[0] == product_id]
    kinds = {entry[1] for entry in sources_for_product}
    if kinds != {"pcgamingwiki", "publisher"}:
        raise RuntimeError(
            f"{product_id} requires reviewed PCGamingWiki and publisher checks before marking none"
        )
    if not scan["complete"]:
        raise RuntimeError(f"{product_id} has symlinked files; package scan is incomplete")

    relative_root = "~/" + package_root.relative_to(Path.home()).as_posix()
    scan_evidence = {
        **scan,
        "packageIdentity": identity,
        "root": relative_root,
        "signatureSet": "anti-cheat-signatures-v1.json",
        "signatureVersion": signatures["version"],
    }
    public_checks = [
        {
            "source": database["antiCheatReference"],
            "checkedAt": checked_at,
            "result": "No exact normalized title record with an anti-cheat technology in the pinned AWACY dataset.",
            "sourceType": "awacy",
        }
    ]
    for _, kind, url, _ in sources_for_product:
        public_checks.append(
            {
                "source": url,
                "checkedAt": checked_at,
                "result": "Reviewed page/search results; no anti-cheat technology record for this Windows PC title.",
                "sourceType": kind,
            }
        )

    if scan["matches"]:
        technology_names = sorted(scan["matches"])
        product["antiCheat"] = "; ".join(technology_names)
        scan_evidence["result"] = "named"
    else:
        product["antiCheat"] = "none"
        scan_evidence["result"] = "no-known-signature"
    product["antiCheatEvidence"] = {
        "type": "package-scan",
        "source": next(url for _, kind, url, _ in sources_for_product if kind == "pcgamingwiki"),
        "checkedAt": checked_at,
        "mode": "unknown",
        "method": (
            "Scanned every inventoried relative package path using the versioned anti-cheat "
            "signature set; file contents were not modified. No known signature matched. "
            "The title had no exact AWACY anti-cheat record, and the reviewed PCGamingWiki "
            "and publisher sources had no anti-cheat record."
            if not scan["matches"]
            else "Scanned every inventoried relative package path using the versioned anti-cheat "
            "signature set; matched the named component(s). A package match takes precedence."
        ),
        "packageScan": scan_evidence,
        "publicChecks": public_checks,
    }
    product["supported01"] = (
        product["packageFormat"] == "MSIXVC" and product["antiCheat"] == "none"
    )
    return {
        "productID": product_id,
        "title": product.get("title"),
        "fileCount": scan["fileCount"],
        "fileListSha256": scan["fileListSha256"],
        "signatureMatches": scan["matches"],
        "antiCheat": product["antiCheat"],
        "supported01": product["supported01"],
        "scanRoot": relative_root,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        action="append",
        type=parse_root,
        required=True,
        help="PRODUCTID=/absolute/path to the installed/extracted package",
    )
    parser.add_argument(
        "--public-check",
        action="append",
        type=parse_public_source,
        default=[],
        help="manually reviewed public source: PRODUCTID=pcgamingwiki|publisher=https-url=no-anticheat-record",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="record scan evidence in the checked-in catalogue (otherwise report only)",
    )
    args = parser.parse_args()
    if len({product_id for product_id, _ in args.root}) != len(args.root):
        raise RuntimeError("Each product may have only one scanned package root")
    database = load_json(CATALOGUE)
    signatures = load_json(SIGNATURES)
    publisher_products = load_json(PUBLISHER_EVIDENCE).get("products", {})
    checked_at = dt.datetime.now(dt.timezone.utc).date().isoformat()
    reports = [
        update_product(
            database,
            product_id,
            package_root,
            args.public_check,
            signatures,
            publisher_products,
            checked_at,
        )
        for product_id, package_root in args.root
    ]
    if args.apply:
        CATALOGUE.write_text(
            json.dumps(database, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    print(json.dumps(reports, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"package scan error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
