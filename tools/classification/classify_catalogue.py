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
NEXT_30_QUEUE = DATA_DIR / "next-30-queue.json"
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
        content_length = response.headers.get("Content-Length", "0")
        if content_length.isdigit() and int(content_length) > 16 * 1024 * 1024:
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
        prior_anti_cheat = product.get("antiCheat")
        prior_references = product.get("technologyReferences", [])
        prior_launch_proof = product.get("launchProof", [])
        product.update(results[product_id])
        anti_cheat, evidence, references = anti_cheat_classification(
            product_id, product, awacy, publisher_products, checked_at, awacy_url
        )
        if (
            anti_cheat.lower() in {"none", "unknown"}
            and isinstance(prior_evidence, dict)
            and (
                prior_evidence.get("type") == "package-scan"
                or (
                    prior_evidence.get("type") == "unknown"
                    and isinstance(prior_evidence.get("packageScan"), dict)
                )
            )
        ):
            anti_cheat = product["antiCheat"]
            evidence = prior_evidence
        elif (
            anti_cheat.lower() in {"none", "unknown"}
            and isinstance(prior_evidence, dict)
            and prior_evidence.get("type") == "public-source"
            and prior_evidence.get("sourceType") == "pcgamingwiki"
            and isinstance(prior_anti_cheat, str)
            and prior_anti_cheat.lower() not in {"none", "unknown"}
        ):
            anti_cheat = prior_anti_cheat
            evidence = prior_evidence
            references = prior_references
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
    native_providers = database.get("nativeProviders", [])
    if not isinstance(native_providers, list):
        raise RuntimeError("nativeProviders must be a list")
    native_provider_by_id: dict[str, dict[str, Any]] = {}
    for provider in native_providers:
        if not isinstance(provider, dict):
            raise RuntimeError("nativeProviders entries must be objects")
        provider_id = provider.get("id")
        product_id = provider.get("productID")
        evidence = provider.get("evidence")
        signature = provider.get("signature")
        architectures = provider.get("architectures")
        if (
            not isinstance(provider_id, str)
            or not provider_id
            or provider_id in native_provider_by_id
            or provider.get("type") != "native-macos-app"
            or provider.get("platform") != "macOS"
            or not isinstance(product_id, str)
            or product_id not in products
            or products[product_id].get("productRole") != "game"
            or not isinstance(provider.get("bundleIdentifier"), str)
            or not provider["bundleIdentifier"]
            or not isinstance(provider.get("appVersion"), str)
            or not provider["appVersion"]
            or not isinstance(architectures, list)
            or not architectures
            or len(architectures) != len(set(architectures))
            or not all(architecture in {"arm64", "x86_64"} for architecture in architectures)
            or not isinstance(signature, dict)
            or signature.get("verified") is not True
            or not isinstance(signature.get("teamIdentifier"), str)
            or not signature["teamIdentifier"]
            or not isinstance(evidence, dict)
            or evidence.get("sourceType") != "local-app-inspection"
            or not isinstance(evidence.get("source"), str)
            or not evidence["source"].startswith("https://")
            or not isinstance(evidence.get("checkedAt"), str)
            or not re.match(r"^\d{4}-\d{2}-\d{2}$", evidence["checkedAt"])
            or not isinstance(evidence.get("method"), str)
            or not evidence["method"]
            or not isinstance(evidence.get("localPath"), str)
            or not evidence["localPath"].startswith("~/")
        ):
            raise RuntimeError(f"{provider_id!r}: malformed native macOS provider record")
        launcher_product_id = provider.get("storeLauncherProductID")
        if launcher_product_id is not None and (
            not isinstance(launcher_product_id, str)
            or launcher_product_id not in products
            or products[launcher_product_id].get("productRole") != "native-launcher"
        ):
            raise RuntimeError(
                f"{provider_id}: storeLauncherProductID must reference a native launcher"
            )
        native_provider_by_id[provider_id] = provider
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
        public_checks = anti_cheat_evidence.get("publicChecks")
        if evidence_type == "public-source" and normalized_anti_cheat in {"none", "unknown"}:
            user_directed_none = (
                normalized_anti_cheat == "none"
                and isinstance(anti_cheat_evidence.get("method"), str)
                and anti_cheat_evidence["method"].startswith("User-directed classification: ")
                and isinstance(public_checks, list)
                and any(
                    isinstance(check, dict) and check.get("sourceType") == "pcgamingwiki"
                    for check in public_checks
                )
            )
            if not user_directed_none:
                raise RuntimeError(
                    f"{product_id}: public-source evidence must name an anti-cheat technology "
                    "unless a user-directed none classification is explicitly documented"
                )
        if public_checks is not None and (
            not isinstance(public_checks, list)
            or not all(
                isinstance(check, dict)
                and check.get("sourceType") in {"awacy", "pcgamingwiki", "publisher"}
                and isinstance(check.get("source"), str)
                and check["source"].startswith("https://")
                and isinstance(check.get("checkedAt"), str)
                and re.match(r"^\d{4}-\d{2}-\d{2}(?:T.*Z)?$", check["checkedAt"])
                and isinstance(check.get("result"), str)
                and check["result"]
                for check in public_checks
            )
        ):
            raise RuntimeError(f"{product_id}: malformed anti-cheat publicChecks records")
        if evidence_type == "package-scan" or "packageScan" in anti_cheat_evidence:
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
                    evidence_type != "package-scan"
                    or scan.get("result") != "no-known-signature"
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
                if (
                    evidence_type != "unknown"
                    or scan.get("result") != "no-known-signature"
                    or matches
                    or scan.get("symlinkCount") != 0
                ):
                    raise RuntimeError(
                        f"{product_id}: an unknown package scan must be clean and retain unknown"
                    )
            elif (
                evidence_type != "package-scan"
                or scan.get("result") != "named"
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
        role = product.get("productRole")
        if role is not None and role not in {
            "game",
            "native-launcher",
            "entitlement-bundle",
        }:
            raise RuntimeError(f"{product_id}: unsupported productRole")
        launch_mode = product.get("launchMode")
        if launch_mode is not None and launch_mode not in {
            "native-launcher",
            "native-macos-provider",
        }:
            raise RuntimeError(f"{product_id}: unsupported launchMode")
        if launch_mode in {"native-launcher", "native-macos-provider"} and role != "game":
            raise RuntimeError(f"{product_id}: native launchMode requires a game product")
        if role == "entitlement-bundle":
            components = product.get("componentProductIDs")
            if (
                not isinstance(components, list)
                or not components
                or not all(isinstance(component_id, str) for component_id in components)
                or len(components) != len(set(components))
                or any(
                    component_id not in products
                    or products[component_id].get("productRole")
                    not in {"game", "native-launcher"}
                    for component_id in components
                )
            ):
                raise RuntimeError(
                    f"{product_id}: entitlement bundle must reference known game or launcher products"
                )
        if role in {"native-launcher", "entitlement-bundle"} and supported is not None:
            raise RuntimeError(f"{product_id}: non-game product role must not claim game support")
        for key in ("entitlementProductID", "launchViaProductID"):
            reference = product.get(key)
            if reference is not None and (
                not isinstance(reference, str) or reference not in products
            ):
                raise RuntimeError(f"{product_id}: {key} does not reference a catalogue product")
            if (
                reference is not None
                and key == "entitlementProductID"
                and products[reference].get("productRole") != "entitlement-bundle"
            ):
                raise RuntimeError(f"{product_id}: entitlementProductID must reference a bundle")
            if (
                reference is not None
                and key == "launchViaProductID"
                and products[reference].get("productRole") != "native-launcher"
            ):
                raise RuntimeError(f"{product_id}: launchViaProductID must reference a launcher")
        if launch_mode == "native-launcher" and not product.get("launchViaProductID"):
            raise RuntimeError(f"{product_id}: native-launcher launchMode requires launchViaProductID")
        provider_id = product.get("nativeProviderID")
        if launch_mode == "native-macos-provider":
            provider = native_provider_by_id.get(provider_id)
            if provider is None or provider.get("productID") != product_id:
                raise RuntimeError(
                    f"{product_id}: native-macos-provider requires a matching nativeProviderID"
                )
        elif provider_id is not None:
            raise RuntimeError(
                f"{product_id}: nativeProviderID requires native-macos-provider launchMode"
            )
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
    for provider_id, provider in native_provider_by_id.items():
        product = products[provider["productID"]]
        if (
            product.get("nativeProviderID") != provider_id
            or product.get("launchMode") != "native-macos-provider"
        ):
            raise RuntimeError(f"{provider_id}: provider must be linked from its game product")
    candidate_queue = database.get("testCandidates")
    if candidate_queue is not None:
        items = candidate_queue.get("items") if isinstance(candidate_queue, dict) else None
        if (
            not isinstance(candidate_queue, dict)
            or not isinstance(candidate_queue.get("rankingMethod"), str)
            or not isinstance(candidate_queue.get("antiCheatPolicy"), str)
            or not isinstance(items, list)
            or len(items) != 30
        ):
            raise RuntimeError("testCandidates must contain a ranked 30-title queue")
        ranks: set[int] = set()
        candidate_ids: set[str] = set()
        for item in items:
            if not isinstance(item, dict):
                raise RuntimeError("testCandidates items must be objects")
            candidate_id = item.get("productID")
            rank = item.get("rank")
            score = item.get("priorityScore")
            evidence_url = item.get("popularityEvidenceURL")
            public_status = item.get("publicScreeningStatus")
            product = products.get(candidate_id) if isinstance(candidate_id, str) else None
            if (
                product is None
                or not isinstance(rank, int)
                or isinstance(rank, bool)
                or rank < 1
                or not isinstance(score, (int, float))
                or isinstance(score, bool)
                or not isinstance(evidence_url, str)
                or not evidence_url.startswith("https://")
                or public_status
                not in {
                    "confirmed-none-package-and-public-evidence",
                    "likely-none-public-sources",
                    "public-evidence-incomplete",
                    "public-screening-pending",
                    "runtime-unverified",
                }
                or product.get("packageFormat") != "MSIXVC"
                or product.get("antiCheat", "unknown").lower()
                not in {"none", "unknown"}
            ):
                raise RuntimeError(f"testCandidates contains malformed entry {candidate_id!r}")
            if rank in ranks or candidate_id in candidate_ids:
                raise RuntimeError("testCandidates ranks and product IDs must be unique")
            ranks.add(rank)
            candidate_ids.add(candidate_id)
        if ranks != set(range(1, 31)):
            raise RuntimeError("testCandidates ranks must be consecutive from 1 through 30")
    return totals


def validate_next30_queue(database: dict[str, Any]) -> None:
    artifact = load_json(NEXT_30_QUEUE)
    if not isinstance(artifact, dict):
        raise RuntimeError("next-30-queue.json must be an object")
    candidates = database.get("testCandidates", {}).get("items")
    items = artifact.get("items")
    if (
        artifact.get("schemaVersion") != 1
        or artifact.get("sourceCatalogue") != CATALOGUE.name
        or not isinstance(candidates, list)
        or not isinstance(items, list)
        or len(candidates) != 30
        or len(items) != 30
    ):
        raise RuntimeError("next-30-queue.json must mirror the 30-title catalogue queue")
    products = database["products"]
    inspection_path = DATA_DIR / "queue-inspection-v1.json"
    inspection = load_json(inspection_path)
    if (
        not isinstance(inspection, dict)
        or not isinstance(inspection.get("checkedAt"), str)
        or not isinstance(inspection.get("products"), dict)
        or set(inspection["products"]) != {item.get("productID") for item in candidates}
        or artifact.get("assessedAlternatives") != inspection.get("assessedAlternatives")
    ):
        raise RuntimeError("queue inspection evidence is missing or does not match the queue")
    for candidate, item in zip(candidates, items):
        if not isinstance(item, dict):
            raise RuntimeError("next-30-queue.json entries must be objects")
        product_id = candidate.get("productID")
        product = products.get(product_id)
        size = item.get("sizeBytes")
        installed = item.get("alreadyInstalled")
        if (
            product is None
            or item.get("rank") != candidate.get("rank")
            or item.get("storeId") != product_id
            or item.get("title") != candidate.get("title")
            or item.get("antiCheat") != product.get("antiCheat")
            or item.get("packageFormat") != product.get("packageFormat")
            or item.get("entitlementStatus")
            != candidate.get("entitlementStatus", "unverified")
            or item.get("releaseStatus") != candidate.get("releaseStatus", "unverified")
            or item.get("api") not in {"DX9", "DX10", "DX11", "DX12", "Vulkan", "OpenGL"}
            or not isinstance(item.get("apiEvidence"), str)
            or not item["apiEvidence"]
            or item.get("apiBasis") not in {
                "public-Windows-requirement", "public-title-reference",
                "publisher-and-package-layout", "package-layout-inference",
                "engine-inference", "managed-backend-marker", "renderer-library-import",
            }
            or not isinstance(item.get("apiEvidenceSource"), str)
            or not item["apiEvidenceSource"].startswith("https://")
            or not isinstance(item.get("signInEvidence"), dict)
            or (
                item.get("signInNeeded") is not None
                and item.get("signInEvidence", {}).get("basis")
                not in {"public-title-reference", "runtime"}
            )
            or item.get("inspectionEvidence")
            != f"{inspection_path.name}#/products/{product_id}"
            or item.get("apiEvidenceCheckedAt") != inspection["checkedAt"][:10]
            or (
                item.get("signInNeeded") is not None
                and not isinstance(item["signInNeeded"], bool)
            )
            or not isinstance(installed, bool)
            or item.get("sizeBasis")
            != (
                "sum of local file sizes in the installed root; not download size"
                if installed
                else "not measured locally"
            )
            or not isinstance(item.get("signInStatus"), str)
            or not item["signInStatus"]
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
            or item.get("sizeKnown") is not (size > 0)
            or not isinstance(item.get("downloadSizeBytes"), int)
            or isinstance(item["downloadSizeBytes"], bool)
            or item["downloadSizeBytes"] < 0
            or item.get("downloadSizeKnown") is not (item["downloadSizeBytes"] > 0)
            or not isinstance(item.get("downloadSizeEvidence"), dict)
            or not isinstance(item["downloadSizeEvidence"].get("source"), str)
            or not item["downloadSizeEvidence"]["source"].startswith("https://")
            or (
                installed
                and (
                    not isinstance(item.get("installRoot"), str)
                    or not item["installRoot"].startswith("~/Games/Xodus/")
                )
            )
            or (
                not installed
                and (size != 0 or item.get("installRoot") is not None)
            )
            or not isinstance(item.get("antiCheatEvidenceSource"), str)
            or not item["antiCheatEvidenceSource"].startswith("https://")
            or item.get("antiCheatEvidenceCheckedAt")
            != product.get("antiCheatEvidence", {}).get("checkedAt")
        ):
            raise RuntimeError(
                f"next-30-queue.json has stale or malformed entry {product_id!r}"
            )
        observed = inspection["products"][product_id].get("package")
        if installed and (
            not isinstance(observed, dict)
            or observed.get("identity", {}).get("storeId") != product_id
            or observed.get("root") != item.get("installRoot")
            or observed.get("metadata") != item["signInEvidence"].get("manifestFields")
        ):
            raise RuntimeError(f"{product_id}: installed queue evidence has a mismatched identity")
    for alternative in artifact["assessedAlternatives"]:
        named = alternative.get("namedAntiCheatObserved", [])
        product = products.get(alternative.get("storeId"))
        if product is None or (named and (
            product.get("antiCheat") != "; ".join(named)
            or product.get("supported01") is not False
        )):
            raise RuntimeError("Assessed alternative contradicts the anti-cheat catalogue")


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
    validate_next30_queue(database)
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
