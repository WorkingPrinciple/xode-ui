#!/usr/bin/env python3
"""Refresh and validate the embedded package-format and anti-cheat catalogue."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import re
import sys
import unicodedata
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "Sources/XodusManagement/Resources/CompatibilityData"
CATALOGUE = DATA_DIR / "game-compatibility-v1.json"
PUBLISHER_EVIDENCE = DATA_DIR / "publisher-anti-cheat-v1.json"
CATALOGUE_ENDPOINT = "https://displaycatalog.mp.microsoft.com/v7.0/products"
USER_AGENT = "XodusCompatibilityClassification/1.0"
FORMATS = {
    "MSIXVC": "MSIXVC",
    "EAppx": "EAppx",
    "EAppxBundle": "EAppx",
    "MSIX": "MSIX",
    "MsixBundle": "MSIX",
    "MSIXBundle": "MSIX",
    "Appx": "Appx",
    "appx": "Appx",
    "AppxBundle": "Appx",
}


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def normalized_title(value: str) -> str:
    ascii_title = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", " ", ascii_title.lower()).strip()


def catalog_url(product_id: str, market: str) -> str:
    query = urllib.parse.urlencode(
        {"bigIds": product_id, "market": market, "languages": "en-US"}
    )
    return f"{CATALOGUE_ENDPOINT}?{query}"


def request_json(url: str) -> dict[str, Any] | list[Any]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=45) as response:
        if response.status != 200:
            raise RuntimeError(f"Unexpected HTTP status {response.status} for {url}")
        if response.headers.get("Content-Length", "0").isdigit() and int(
            response.headers["Content-Length"]
        ) > 16 * 1024 * 1024:
            raise RuntimeError(f"Response exceeded the 16 MiB evidence bound: {url}")
        body = response.read(16 * 1024 * 1024 + 1)
    if len(body) > 16 * 1024 * 1024:
        raise RuntimeError(f"Response exceeded the 16 MiB evidence bound: {url}")
    return json.loads(body)


def catalog_batch_evidence(product_ids: list[str], market: str) -> dict[str, dict[str, Any]]:
    query = urllib.parse.urlencode(
        {"bigIds": ",".join(product_ids), "market": market, "languages": "en-US"}
    )
    payload = request_json(f"{CATALOGUE_ENDPOINT}?{query}")
    if not isinstance(payload, dict) or not isinstance(payload.get("Products"), list):
        raise RuntimeError(f"Malformed Microsoft catalog response for {product_ids[0]}")
    found: dict[str, dict[str, Any]] = {}
    for product in payload["Products"]:
        product_id = product.get("ProductId")
        if product_id not in product_ids:
            continue
        observed_formats: set[str] = set()
        for availability in product.get("DisplaySkuAvailabilities", []):
            sku = availability.get("Sku") or {}
            for package in (sku.get("Properties") or {}).get("Packages", []):
                package_format = package.get("PackageFormat")
                if isinstance(package_format, str) and package_format:
                    observed_formats.add(package_format)
        raw_formats = sorted(observed_formats)
        family = next(
            (FORMATS[package_format] for package_format in ("MSIXVC",) if package_format in observed_formats),
            None,
        )
        if family is None:
            family = next(
                (
                    FORMATS[package_format]
                    for package_format in (
                        "EAppx",
                        "EAppxBundle",
                        "MSIX",
                        "MsixBundle",
                        "MSIXBundle",
                        "Appx",
                        "appx",
                        "AppxBundle",
                    )
                    if package_format in observed_formats
                ),
                None,
            )
        if family is None:
            family = next((item for item in ("XVC", "Xap") if item in observed_formats), None)
        if family is None and raw_formats:
            family = raw_formats[0]
        found[product_id] = {
            "packageFormat": family or "unknown",
            "packageFormatEvidence": {
                "source": catalog_url(product_id, market),
                "checkedAt": dt.datetime.now(dt.timezone.utc).date().isoformat(),
                "catalogModifiedAt": product.get("LastModifiedDate"),
                "observedFormats": raw_formats,
                "method": (
                    "Read DisplaySkuAvailabilities[].Sku.Properties.Packages[].PackageFormat "
                    "from the product's Microsoft Display Catalog response. Bundle formats "
                    "are normalized to their package family; observedFormats preserves the "
                    "exact catalog values."
                    if raw_formats
                    else "The returned product record contains no SKU package formats. "
                    "No installed package files were inspected; format remains unknown."
                ),
            },
        }
    for product_id in product_ids:
        if product_id not in found:
            raise RuntimeError(
                f"Expected Microsoft catalog product {product_id} in batch response"
            )
    return found


def awacy_index(url: str) -> dict[str, list[dict[str, Any]]]:
    payload = request_json(url)
    if not isinstance(payload, list) or len(payload) > 10000:
        raise RuntimeError("Malformed or unexpectedly large AWACY catalogue")
    index: dict[str, list[dict[str, Any]]] = {}
    for game in payload:
        name = game.get("name")
        if isinstance(name, str) and name.strip():
            index.setdefault(normalized_title(name), []).append(game)
    return index


def anti_cheat_classification(
    product_id: str,
    product: dict[str, Any],
    awacy: dict[str, list[dict[str, Any]]],
    publisher_products: dict[str, dict[str, Any]],
    checked_at: str,
    awacy_url: str,
) -> tuple[str, dict[str, Any], list[str]]:
    publisher = publisher_products.get(product_id)
    if publisher is not None:
        technologies = publisher.get("technologies")
        source = publisher.get("source")
        publisher_date = publisher.get("checkedAt")
        if (
            isinstance(technologies, list)
            and technologies
            and isinstance(source, str)
            and isinstance(publisher_date, str)
        ):
            return (
                "; ".join(technologies),
                {
                    "type": "public-source",
                    "source": source,
                    "checkedAt": publisher_date,
                    "mode": "unknown",
                    "scope": publisher.get("scope", ""),
                    "method": "Publisher-authored evidence record names this anti-cheat "
                    "for the Windows PC title. Kernel/user mode was not established.",
                },
                technologies,
            )

    title = product.get("title")
    matches = awacy.get(normalized_title(title or ""), [])
    if len(matches) == 1:
        technologies = matches[0].get("anticheats")
        if isinstance(technologies, list) and technologies:
            names = sorted({name.strip() for name in technologies if isinstance(name, str) and name.strip()})
            if names:
                return (
                    "; ".join(names),
                    {
                        "type": "public-source",
                        "source": awacy_url,
                        "checkedAt": checked_at,
                        "mode": "unknown",
                        "method": "Exact normalized title match in the pinned AWACY games "
                        "dataset; its anticheats field lists these technologies. "
                        "Kernel/user mode was not established.",
                    },
                    names,
                )
    elif len(matches) > 1:
        technologies = {
            name.strip()
            for match in matches
            for name in match.get("anticheats", [])
            if isinstance(name, str) and name.strip()
        }
        if technologies:
            raise RuntimeError(
                f"Ambiguous AWACY title match for {product_id} ({title!r}); "
                "review before classifying."
            )

    return (
        "unknown",
        {
            "type": "unknown",
            "source": awacy_url,
            "checkedAt": checked_at,
            "mode": "unknown",
            "method": (
                "Searched the pinned AWACY dataset for an exact normalized title and "
                "checked the bundled publisher-evidence records for this product ID; "
                "no affirmative anti-cheat result was found. No installed package files "
                "or per-title PCGamingWiki/publisher pages were inspected. This is "
                "unknown, not evidence that the game has no anti-cheat."
            ),
        },
        [],
    )


def supported01(package_format: str, anti_cheat: str) -> bool | None:
    anti_cheat = anti_cheat.lower()
    if package_format == "MSIXVC" and anti_cheat == "none":
        return True
    if package_format != "unknown" and package_format != "MSIXVC":
        return False
    if anti_cheat not in {"none", "unknown"}:
        return False
    return None


def refresh(database: dict[str, Any]) -> dict[str, Any]:
    products = database.get("products")
    market = database.get("market")
    awacy_url = database.get("antiCheatReference")
    if not isinstance(products, dict) or not isinstance(market, str) or not isinstance(awacy_url, str):
        raise RuntimeError("Catalogue is missing products, market, or pinned anti-cheat source")
    checked_at = dt.datetime.now(dt.timezone.utc).date().isoformat()
    publisher_data = load_json(PUBLISHER_EVIDENCE)
    publisher_products = publisher_data.get("products", {})
    awacy = awacy_index(awacy_url)

    ids = list(products)
    results: dict[str, dict[str, Any]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        batches = [ids[index : index + 10] for index in range(0, len(ids), 10)]
        futures = [executor.submit(catalog_batch_evidence, batch, market) for batch in batches]
        for future in concurrent.futures.as_completed(futures):
            results.update(future.result())

    for product_id, product in products.items():
        prior_evidence = product.get("antiCheatEvidence")
        prior_launch_proof = product.get("launchProof", [])
        product.update(results[product_id])
        anti_cheat, evidence, references = anti_cheat_classification(
            product_id, product, awacy, publisher_products, checked_at, awacy_url
        )
        if (
            anti_cheat.lower() in {"none", "unknown"}
            and isinstance(prior_evidence, dict)
            and prior_evidence.get("type") == "package-scan"
        ):
            anti_cheat = product["antiCheat"]
            evidence = prior_evidence
        product["antiCheat"] = anti_cheat
        product["antiCheatEvidence"] = evidence
        product["technologyReferences"] = references
        product["launchProof"] = prior_launch_proof
        product["supported01"] = supported01(product["packageFormat"], anti_cheat)

    database["checkedAt"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )
    return database


def validate(database: dict[str, Any]) -> Counter[str]:
    products = database.get("products")
    if not isinstance(products, dict) or not products:
        raise RuntimeError("Catalogue has no product records")
    totals: Counter[str] = Counter()
    for product_id, product in products.items():
        if not isinstance(product, dict):
            raise RuntimeError(f"{product_id}: product record must be an object")
        package_format = product.get("packageFormat")
        anti_cheat = product.get("antiCheat")
        supported = product.get("supported01")
        package_evidence = product.get("packageFormatEvidence")
        anti_cheat_evidence = product.get("antiCheatEvidence")
        if not isinstance(package_format, str) or not package_format:
            raise RuntimeError(f"{product_id}: packageFormat must be explicit")
        if not isinstance(anti_cheat, str) or not anti_cheat:
            raise RuntimeError(f"{product_id}: antiCheat must be explicit")
        if len(anti_cheat.encode("utf-8")) > 128:
            raise RuntimeError(f"{product_id}: antiCheat exceeds the 128-byte bound")
        if not isinstance(package_evidence, dict) or not isinstance(anti_cheat_evidence, dict):
            raise RuntimeError(f"{product_id}: package and anti-cheat evidence are required")
        for label, evidence in (
            ("packageFormatEvidence", package_evidence),
            ("antiCheatEvidence", anti_cheat_evidence),
        ):
            source = evidence.get("source")
            checked = evidence.get("checkedAt")
            method = evidence.get("method")
            if (
                not isinstance(source, str)
                or not source.startswith("https://")
                or not isinstance(checked, str)
                or not re.match(r"^\d{4}-\d{2}-\d{2}(?:T.*Z)?$", checked)
                or not isinstance(method, str)
                or not method
            ):
                raise RuntimeError(f"{product_id}: invalid {label} source, date, or method")
        observed = package_evidence.get("observedFormats")
        if not isinstance(observed, list) or not all(isinstance(item, str) for item in observed):
            raise RuntimeError(f"{product_id}: observedFormats must be a list of strings")
        if (package_format == "unknown") != (not observed):
            raise RuntimeError(
                f"{product_id}: unknown packageFormat must correspond to empty observedFormats"
            )
        evidence_type = anti_cheat_evidence.get("type")
        if evidence_type not in {"public-source", "unknown", "package-scan"}:
            raise RuntimeError(f"{product_id}: unsupported antiCheatEvidence.type")
        normalized_anti_cheat = anti_cheat.lower()
        if evidence_type == "unknown" and normalized_anti_cheat != "unknown":
            raise RuntimeError(f"{product_id}: unknown evidence must keep antiCheat unknown")
        if evidence_type == "public-source" and normalized_anti_cheat in {"none", "unknown"}:
            raise RuntimeError(
                f"{product_id}: public-source evidence must name an anti-cheat technology"
            )
        if evidence_type == "package-scan":
            scan = anti_cheat_evidence.get("packageScan")
            if not isinstance(scan, dict):
                raise RuntimeError(f"{product_id}: package-scan evidence is missing packageScan")
            file_count = scan.get("fileCount")
            file_hash = scan.get("fileListSha256")
            matches = scan.get("matches")
            if (
                not isinstance(file_count, int)
                or isinstance(file_count, bool)
                or file_count < 0
                or not isinstance(file_hash, str)
                or not re.fullmatch(r"[0-9a-f]{64}", file_hash)
                or not isinstance(matches, dict)
                or not all(
                    isinstance(name, str)
                    and isinstance(paths, list)
                    and paths
                    and all(isinstance(path, str) and path for path in paths)
                    for name, paths in matches.items()
                )
                or scan.get("complete") is not True
                or not isinstance(scan.get("signatureSet"), str)
                or not isinstance(scan.get("signatureVersion"), int)
                or isinstance(scan.get("signatureVersion"), bool)
                or not isinstance(scan.get("root"), str)
                or not scan["root"].startswith("~/")
            ):
                raise RuntimeError(f"{product_id}: malformed package-scan inventory evidence")
            identity = scan.get("packageIdentity")
            if (
                not isinstance(identity, dict)
                or identity.get("storeId") != product_id
                or not isinstance(identity.get("name"), str)
                or not isinstance(identity.get("version"), str)
            ):
                raise RuntimeError(f"{product_id}: package-scan identity does not match the product")
            public_checks = anti_cheat_evidence.get("publicChecks")
            if not isinstance(public_checks, list) or not all(
                isinstance(check, dict)
                and check.get("sourceType") in {"awacy", "pcgamingwiki", "publisher"}
                and isinstance(check.get("source"), str)
                and check["source"].startswith("https://")
                and isinstance(check.get("checkedAt"), str)
                and re.match(r"^\d{4}-\d{2}-\d{2}(?:T.*Z)?$", check["checkedAt"])
                and isinstance(check.get("result"), str)
                and check["result"]
                for check in public_checks
            ):
                raise RuntimeError(
                    f"{product_id}: malformed package-scan publicChecks records"
                )
            if normalized_anti_cheat == "none":
                checked_types = {
                    check.get("sourceType")
                    for check in public_checks
                }
                if (
                    scan.get("result") != "no-known-signature"
                    or matches
                    or scan.get("symlinkCount") != 0
                    or len(public_checks) != 3
                    or checked_types != {"awacy", "pcgamingwiki", "publisher"}
                ):
                    raise RuntimeError(
                        f"{product_id}: none requires a clean scan and AWACY, PCGamingWiki, "
                        "and publisher checks"
                    )
            elif normalized_anti_cheat == "unknown":
                raise RuntimeError(f"{product_id}: package scan cannot classify antiCheat as unknown")
            elif (
                scan.get("result") != "named"
                or not matches
                or set(anti_cheat.split("; ")) != set(matches)
            ):
                raise RuntimeError(
                    f"{product_id}: named package-scan anti-cheat must match signature hits"
                )
        launch_proof = product.get("launchProof")
        if not isinstance(launch_proof, list) or not all(
            isinstance(item, dict) for item in launch_proof
        ):
            raise RuntimeError(f"{product_id}: launchProof must be a list of proof records")
        expected = supported01(package_format, anti_cheat)
        if supported is not expected:
            raise RuntimeError(
                f"{product_id}: supported01={supported!r}, expected {expected!r}"
            )
        totals[
            "true" if supported is True else "false" if supported is False else "unknown"
        ] += 1
        totals[f"antiCheat:{'none' if anti_cheat.lower() == 'none' else 'unknown' if anti_cheat.lower() == 'unknown' else 'named'}"] += 1
        totals[f"packageFormat:{package_format}"] += 1
    return totals


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="query Microsoft Display Catalog and pinned AWACY source, then update the JSON",
    )
    args = parser.parse_args()
    database = load_json(CATALOGUE)
    if args.refresh:
        database = refresh(database)
        CATALOGUE.write_text(
            json.dumps(database, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    totals = validate(database)
    print(
        f"{len(database['products'])} products; supported01 "
        f"true={totals['true']} false={totals['false']} unknown={totals['unknown']}"
    )
    print(
        "antiCheat "
        f"none={totals['antiCheat:none']} named={totals['antiCheat:named']} "
        f"unknown={totals['antiCheat:unknown']}"
    )
    for key, value in sorted(totals.items()):
        if key.startswith("packageFormat:"):
            print(f"{key.removeprefix('packageFormat:')}: {value}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        print(f"classification error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
